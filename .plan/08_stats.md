# 统计模块 (erwind_stats)

## 功能概述

统计模块负责收集和聚合系统运行指标，包括消息速率、队列深度、连接数等，为监控和告警提供数据支持。

## 原理详解

### 统计指标

#### 1. 全局指标
- `start_time`: 启动时间
- `uptime`: 运行时长
- `version`: 版本号
- `memory`: 内存使用

#### 2. Topic 指标
- `message_count`: 接收消息总数
- `message_rate`: 消息接收速率（msg/s）
- `depth`: 当前队列深度
- `backend_depth`: 磁盘队列深度
- `paused`: 是否暂停

#### 3. Channel 指标
- `depth`: 队列深度
- `in_flight_count`: 在途消息数
- `deferred_count`: 延迟消息数
- `message_count`: 处理消息总数
- `requeue_count`: 重入队次数
- `timeout_count`: 超时次数
- `consumer_count`: 消费者数量

#### 4. 消费者指标
- `rdy_count`: Ready 计数
- `in_flight_count`: 在途消息数
- `finish_count`: 完成消息数
- `requeue_count`: 重入队次数
- `connect_time`: 连接时间

### 统计聚合

```
                    +----------------+
   Topic Stats      |  erwind_stats  |
  +---------------->+   (ETS 表)     |
                    +--------+-------+
   Channel Stats             |
  +---------------->         |
                            v
                    +----------------+
   Consumer Stats   |  Statsd/       |
  +---------------->+  Prometheus    |
                    +----------------+
```

## Erlang 实现设计

### 模块结构

```erlang
-module(erwind_stats).
-behaviour(gen_server).

%% API
-export([start_link/0, incr/2, decr/2, gauge/2, timing/2]).
-export([get_topic_stats/1, get_channel_stats/2, get_global_stats/0]).
-export([report_to_statsd/0, report_to_prometheus/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ETS 表名定义
-define(TOPIC_STATS, erwind_topic_stats).
-define(CHANNEL_STATS, erwind_channel_stats).
-define(CONSUMER_STATS, erwind_consumer_stats).
-define(GLOBAL_STATS, erwind_global_stats).

-record(stat_counter, {
    key :: term(),
    count = 0 :: non_neg_integer(),
    rate_1m = 0.0 :: float(),
    rate_5m = 0.0 :: float(),
    rate_15m = 0.0 :: float()
}).

-record(state, {
    start_time :: integer(),
    statsd_client :: pid(),
    prometheus_registry :: atom()
}).
```

### 核心逻辑

#### 1. 初始化

```erlang
init([]) ->
    %% 创建 ETS 表
    ets:new(?TOPIC_STATS, [set, named_table, public, 
                           {read_concurrency, true}]),
    ets:new(?CHANNEL_STATS, [set, named_table, public,
                             {read_concurrency, true}]),
    ets:new(?CONSUMER_STATS, [set, named_table, public,
                              {read_concurrency, true}]),
    ets:new(?GLOBAL_STATS, [set, named_table, public,
                            {read_concurrency, true}]),
    
    %% 设置启动时间
    StartTime = erlang:system_time(millisecond),
    ets:insert(?GLOBAL_STATS, {start_time, StartTime}),
    
    %% 启动速率计算定时器
    erlang:send_after(1000, self(), calculate_rates),
    
    {ok, #state{start_time = StartTime}}.
```

#### 2. 计数器操作

```erlang
%% 增加计数
incr(topic, {Topic, Key}) ->
    ets:update_counter(?TOPIC_STATS, {Topic, Key}, {2, 1}, {{Topic, Key}, 0});

incr(channel, {Topic, Channel, Key}) ->
    ets:update_counter(?CHANNEL_STATS, {Topic, Channel, Key}, 
                       {2, 1}, {{Topic, Channel, Key}, 0});

incr(consumer, {Pid, Key}) ->
    ets:update_counter(?CONSUMER_STATS, {Pid, Key}, {2, 1}, {{Pid, Key}, 0});

incr(global, Key) ->
    ets:update_counter(?GLOBAL_STATS, Key, {2, 1}, {Key, 0}).

%% 减少计数
decr(channel, {Topic, Channel, Key}) ->
    ets:update_counter(?CHANNEL_STATS, {Topic, Channel, Key}, 
                       {2, -1}, {{Topic, Channel, Key}, 0}).

%% 设置 Gauge
gauge(topic, {Topic, Key, Value}) ->
    ets:insert(?TOPIC_STATS, {{Topic, Key}, Value});

gauge(channel, {Topic, Channel, Key, Value}) ->
    ets:insert(?CHANNEL_STATS, {{Topic, Channel, Key}, Value}).
```

#### 3. 速率计算

```erlang
%% EWMA (指数加权移动平均) 速率计算
-define(ALPHA_1M, 0.0799555853706767).   %% 1 分钟
-define(ALPHA_5M, 0.0191988897560153).   %% 5 分钟
-define(ALPHA_15M, 0.00652986989124683). %% 15 分钟

handle_info(calculate_rates, State) ->
    %% 计算 Topic 速率
    lists:foreach(fun([Topic]) ->
        calculate_topic_rates(Topic)
    end, ets:match(?TOPIC_STATS, {{'$1', '_'}, '_', '_', '_', '_'})),
    
    %% 计算 Channel 速率
    lists:foreach(fun([Topic, Channel]) ->
        calculate_channel_rates(Topic, Channel)
    end, ets:match(?CHANNEL_STATS, {{'$1', '$2', '_'}, '_', '_', '_', '_'})),
    
    %% 重启定时器
    erlang:send_after(1000, self(), calculate_rates),
    {noreply, State}.

calculate_topic_rates(Topic) ->
    case ets:lookup(?TOPIC_STATS, {Topic, message_count}) of
        [{_, CurrentCount}] ->
            case ets:lookup(?TOPIC_STATS, {Topic, message_count_prev}) of
                [{_, PrevCount}] ->
                    Delta = CurrentCount - PrevCount,
                    
                    %% 更新速率
                    update_ewma({Topic, rate_1m}, Delta, ?ALPHA_1M),
                    update_ewma({Topic, rate_5m}, Delta, ?ALPHA_5M),
                    update_ewma({Topic, rate_15m}, Delta, ?ALPHA_15M);
                [] ->
                    ok
            end,
            
            %% 保存当前值
            ets:insert(?TOPIC_STATS, {{Topic, message_count_prev}, CurrentCount});
        [] ->
            ok
    end.

update_ewma(Key, Delta, Alpha) ->
    case ets:lookup(?GLOBAL_STATS, {ewma, Key}) of
        [{_, CurrentRate}] ->
            NewRate = CurrentRate + Alpha * (Delta - CurrentRate),
            ets:insert(?GLOBAL_STATS, {{ewma, Key}, NewRate});
        [] ->
            ets:insert(?GLOBAL_STATS, {{ewma, Key}, float(Delta)})
    end.
```

#### 4. 获取统计信息

```erlang
%% 获取 Topic 统计
handle_call({get_topic_stats, Topic}, _From, State) ->
    Stats = collect_topic_stats(Topic),
    {reply, {ok, Stats}, State}.

collect_topic_stats(Topic) ->
    #{
        topic => Topic,
        message_count => get_counter(?TOPIC_STATS, {Topic, message_count}),
        message_rate_1m => get_ewma({Topic, rate_1m}),
        message_rate_5m => get_ewma({Topic, rate_5m}),
        message_rate_15m => get_ewma({Topic, rate_15m}),
        depth => get_counter(?TOPIC_STATS, {Topic, depth}),
        backend_depth => get_counter(?TOPIC_STATS, {Topic, backend_depth}),
        paused => get_gauge(?TOPIC_STATS, {Topic, paused})
    }.

%% 获取 Channel 统计
handle_call({get_channel_stats, Topic, Channel}, _From, State) ->
    Stats = collect_channel_stats(Topic, Channel),
    {reply, {ok, Stats}, State}.

collect_channel_stats(Topic, Channel) ->
    #{
        topic => Topic,
        channel => Channel,
        depth => get_counter(?CHANNEL_STATS, {Topic, Channel, depth}),
        in_flight => get_counter(?CHANNEL_STATS, {Topic, Channel, in_flight}),
        deferred => get_counter(?CHANNEL_STATS, {Topic, Channel, deferred}),
        message_count => get_counter(?CHANNEL_STATS, {Topic, Channel, message_count}),
        requeue_count => get_counter(?CHANNEL_STATS, {Topic, Channel, requeue_count}),
        timeout_count => get_counter(?CHANNEL_STATS, {Topic, Channel, timeout_count}),
        consumer_count => get_consumer_count(Topic, Channel)
    }.

get_counter(Table, Key) ->
    case ets:lookup(Table, Key) of
        [{_, Value}] -> Value;
        [] -> 0
    end.
```

#### 5. StatsD 导出

```erlang
%% 导出到 StatsD
handle_info(export_statsd, #state{statsd_client = Client} = State) ->
    %% 导出 Topic 统计
    lists:foreach(fun([Topic]) ->
        Stats = collect_topic_stats(Topic),
        
        statsderl:counter(Client, 
            ["erwind.topic.", Topic, ".messages"],
            maps:get(message_count, Stats)),
        statsderl:gauge(Client,
            ["erwind.topic.", Topic, ".depth"],
            maps:get(depth, Stats)),
        statsderl:gauge(Client,
            ["erwind.topic.", Topic, ".rate_1m"],
            round(maps:get(message_rate_1m, Stats)))
    end, ets:match(?TOPIC_STATS, {{'$1', '_'}, '_', '_', '_', '_'})),
    
    %% 重启定时器
    erlang:send_after(10000, self(), export_statsd),
    {noreply, State}.
```

#### 6. Prometheus 导出

```erlang
%% 初始化 Prometheus 指标
init_prometheus() ->
    prometheus_counter:new([
        {name, erwind_messages_total},
        {help, "Total number of messages"},
        {labels, [topic]}
    ]),
    
    prometheus_gauge:new([
        {name, erwind_topic_depth},
        {help, "Current depth of topic"},
        {labels, [topic]}
    ]),
    
    prometheus_histogram:new([
        {name, erwind_message_duration_seconds},
        {help, "Message processing duration"},
        {labels, [topic, channel]},
        {buckets, [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0]}
    ]).

%% 导出到 Prometheus
handle_info(export_prometheus, State) ->
    %% 更新 Topic 指标
    lists:foreach(fun([Topic]) ->
        Stats = collect_topic_stats(Topic),
        
        prometheus_counter:inc(erwind_messages_total, [Topic],
            maps:get(message_count, Stats)),
        prometheus_gauge:set(erwind_topic_depth, [Topic],
            maps:get(depth, Stats))
    end, ets:match(?TOPIC_STATS, {{'$1', '_'}, '_', '_', '_', '_'})),
    
    {noreply, State}.
```

## 依赖关系

### 依赖的模块
- `statsderl` - StatsD 客户端（可选）
- `prometheus` - Prometheus 客户端（可选）

### 被依赖的模块
- `erwind_topic` - 上报 Topic 统计
- `erwind_channel` - 上报 Channel 统计
- `erwind_tcp_listener` - 上报连接统计
- `erwind_http_api` - 提供 /stats 接口数据

## 接口定义

```erlang
%% 增加计数
-spec incr(Type :: atom(), Key :: term()) -> integer().

%% 设置 Gauge
-spec gauge(Type :: atom(), KeyValue :: term()) -> ok.

%% 记录时间
-spec timing(Key :: term(), Time :: integer()) -> ok.

%% 获取统计
-spec get_topic_stats(Topic :: binary()) -> {ok, map()}.
-spec get_channel_stats(Topic :: binary(), Channel :: binary()) -> {ok, map()}.
-spec get_global_stats() -> {ok, map()}.
```

## 配置参数

```erlang
{erwind_stats, [
    {enabled, true},                    %% 是否启用统计
    {statsd_enabled, false},            %% StatsD 导出
    {statsd_host, "localhost"},
    {statsd_port, 8125},
    {statsd_prefix, "erwind"},
    {statsd_interval, 10000},           %% 导出间隔（毫秒）
    
    {prometheus_enabled, false},        %% Prometheus 导出
    {prometheus_port, 9150},            %% Prometheus 端口
    
    {rate_calculation_interval, 1000}   %% 速率计算间隔（毫秒）
]}.
```
