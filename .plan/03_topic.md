# Topic 模块 (erwind_topic)

## 功能概述

Topic 是消息的逻辑通道，负责接收生产者发布的消息，并将消息分发给其下的所有 Channel。每个 Topic 是一个独立的 gen_server 进程。

## 原理详解

### Topic 的核心职责

1. **消息接收**：接收来自生产者的 PUB/MPUB/DPUB 消息
2. **消息路由**：将消息复制到所有关联的 Channel
3. **Channel 管理**：创建、删除、查询 Channel
4. **持久化**：将消息写入 Backend Queue（防止内存溢出）
5. **统计**：收集消息速率、积压量等指标

### 消息分发模型

```
                    +------------------+
   Producer PUB     |     Topic        |
  +---------------->+  (erwind_topic)  |
                    +--------+---------+
                             |
         +-------------------+-------------------+
         |                   |                   |
+--------v---------+ +-------v--------+ +-------v--------+
|   Channel A      | |   Channel B    | |   Channel C    |
|  (Subscribers)   | |  (Subscribers) | |  (Subscribers) |
+------------------+ +----------------+ +----------------+
```

- 一条消息进入 Topic 后，会**复制**到所有 Channel
- 每个 Channel 独立消费，互不影响
- Channel 内消息被竞争消费（一个消息只被一个消费者处理）

### 内存 vs 磁盘

```
Producer -> Topic
              |
              v
         +---------+
         |  Memory |  <- 优先写入内存队列（快）
         |  Queue  |
         +----+----+
              | 满
              v
         +---------+
         |  Disk   |  <- 内存满时写入磁盘（慢）
         |  Queue  |
         +---------+
```

## Erlang 实现设计

### 模块结构

```erlang
-module(erwind_topic).
-behaviour(gen_server).

%% API
-export([start_link/1, stop/1, publish/2, mpub/2, dpub/3]).
-export([get_channel/2, create_channel/2, delete_channel/2, list_channels/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {
    name :: binary(),                    %% Topic 名称
    channels = #{} :: #{binary() => pid()}, %% Channel 名称 -> PID 映射
    backend :: pid(),                    %% Backend Queue PID
    message_count = 0 :: non_neg_integer(), %% 消息计数
    paused = false :: boolean(),         %% 是否暂停
    ephemeral = false :: boolean(),      %% 是否临时 Topic
    stats = #{} :: map()                 %% 统计信息
}).
```

### 监督者配置

```erlang
%% erwind_topic_sup.erl
%% 使用 simple_one_for_one 策略动态创建 Topic

init([]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 10,
        period => 10
    },
    TopicSpec = #{
        id => erwind_topic,
        start => {erwind_topic, start_link, []},
        restart => temporary,      %% Topic 可关闭，不自动重启
        shutdown => 5000,
        type => worker,
        modules => [erwind_topic]
    },
    {ok, {SupFlags, [TopicSpec]}}.

%% Topic 注册表（ETS）
%% 用于快速查找 Topic PID，避免遍历监督者子进程
init_registry() ->
    ets:new(erwind_topic_registry, [
        set,                    %% 唯一键
        named_table,           %% 具名表
        public,                %% 公开读写
        {read_concurrency, true}  %% 高并发读优化
    ]).
```

### 核心逻辑

#### 1. Topic 生命周期

```erlang
%% 启动 Topic（如果不存在则创建）
get_or_create_topic(TopicName) ->
    case lookup_topic(TopicName) of
        {ok, Pid} ->
            {ok, Pid};
        not_found ->
            supervisor:start_child(erwind_topic_sup, [TopicName])
    end.

%% 查找 Topic
lookup_topic(TopicName) ->
    case ets:lookup(erwind_topic_registry, TopicName) of
        [{_, Pid}] -> {ok, Pid};
        [] -> not_found
    end.

%% 初始化
init([TopicName]) ->
    process_flag(trap_exit, true),
    
    %% 启动 Backend Queue
    {ok, BackendPid} = erwind_backend_queue:start_link(TopicName),
    
    %% 注册到 ETS
    ets:insert(erwind_topic_registry, {TopicName, self()}),
    
    %% 通知 nsqlookupd
    erwind_lookupd:register_topic(TopicName),
    
    {ok, #state{
        name = TopicName,
        backend = BackendPid,
        ephemeral = is_ephemeral(TopicName)
    }}.
```

#### 2. 消息发布

```erlang
%% 单条发布（异步）
handle_cast({publish, Body}, State) ->
    Msg = create_message(Body),
    
    %% 写入 Backend Queue
    erwind_backend_queue:put(State#state.backend, Msg),
    
    %% 分发到所有 Channel
    lists:foreach(fun({_, Pid}) ->
        erwind_channel:put_message(Pid, Msg)
    end, maps:to_list(State#state.channels)),
    
    %% 更新统计
    erwind_stats:incr_topic_msg_count(State#state.name),
    
    {noreply, State#state{
        message_count = State#state.message_count + 1
    }}.

%% 批量发布
handle_cast({mpub, Bodies}, State) ->
    Msgs = [create_message(Body) || Body <- Bodies],
    
    %% 批量写入 Backend
    erwind_backend_queue:put_batch(State#state.backend, Msgs),
    
    %% 批量分发
    lists:foreach(fun(Msg) ->
        lists:foreach(fun({_, Pid}) ->
            erwind_channel:put_message(Pid, Msg)
        end, maps:to_list(State#state.channels))
    end, Msgs),
    
    {noreply, State#state{
        message_count = State#state.message_count + length(Msgs)
    }}.

%% 延迟发布
handle_cast({dpub, Body, DeferMs}, State) ->
    Msg = create_message(Body),
    
    %% 设置延迟定时器
    TimerRef = erlang:send_after(DeferMs, self(), {deferred_publish, Msg}),
    
    %% 存储延迟消息（可用 ETS 或单独进程管理）
    store_deferred_msg(Msg, TimerRef),
    
    {noreply, State}.

%% 延迟到期处理
handle_info({deferred_publish, Msg}, State) ->
    %% 与普通发布相同逻辑
    erwind_backend_queue:put(State#state.backend, Msg),
    lists:foreach(fun({_, Pid}) ->
        erwind_channel:put_message(Pid, Msg)
    end, maps:to_list(State#state.channels)),
    
    {noreply, State}.
```

#### 3. Channel 管理

```erlang
%% 获取或创建 Channel
handle_call({get_channel, ChannelName}, _From, State) ->
    case maps:get(ChannelName, State#state.channels, undefined) of
        undefined ->
            %% 创建新 Channel
            {ok, Pid} = erwind_channel_sup:start_child(
                State#state.name, ChannelName
            ),
            NewChannels = maps:put(ChannelName, Pid, State#state.channels),
            
            %% 监控 Channel
            erlang:monitor(process, Pid),
            
            {reply, {ok, Pid}, State#state{channels = NewChannels}};
        Pid ->
            {reply, {ok, Pid}, State}
    end.

%% 删除 Channel
handle_call({delete_channel, ChannelName}, _From, State) ->
    case maps:get(ChannelName, State#state.channels, undefined) of
        undefined ->
            {reply, {error, not_found}, State};
        Pid ->
            erwind_channel:stop(Pid),
            NewChannels = maps:remove(ChannelName, State#state.channels),
            {reply, ok, State#state{channels = NewChannels}}
    end.

%% Channel 退出处理
handle_info({'DOWN', _Ref, process, Pid, _Reason}, State) ->
    %% 从 channels map 中移除
    NewChannels = maps:filter(fun(_, P) -> P =/= Pid end, State#state.channels),
    
    %% 检查是否是临时 Topic 且无 Channel
    case State#state.ephemeral andalso map_size(NewChannels) == 0 of
        true ->
            %% 临时 Topic 自动关闭
            {stop, normal, State#state{channels = NewChannels}};
        false ->
            {noreply, State#state{channels = NewChannels}}
    end.
```

#### 4. 消息创建

```erlang
%% 创建新消息
-spec create_message(binary()) -> #nsq_message{}.
create_message(Body) ->
    #nsq_message{
        id = erwind_protocol:generate_msg_id(),
        timestamp = erlang:system_time(millisecond),
        attempts = 1,
        body = Body
    }.
```

### 内存管理

```erlang
%% 检查内存使用，必要时暂停写入
handle_info(check_memory, State) ->
    MemUsage = erwind_backend_queue:memory_usage(State#state.backend),
    
    case MemUsage of
        high ->
            %% 暂停接受新消息
            {noreply, State#state{paused = true}};
        normal ->
            {noreply, State#state{paused = false}}
    end.

%% 发布前检查暂停状态
handle_cast({publish, _Body}, #state{paused = true} = State) ->
    %% 返回错误或阻塞
    {noreply, State}.
```

## 依赖关系

### 依赖的模块
- `erwind_backend_queue` - 消息持久化
- `erwind_channel_sup` / `erwind_channel` - Channel 创建和管理
- `erwind_stats` - 统计信息收集
- `erwind_lookupd` - 服务注册

### 被依赖的模块
- `erwind_tcp_listener` - 发布消息时调用
- `erwind_http_api` - 管理接口调用
- `erwind_topic_sup` - 监督者启动

## 接口定义

```erlang
%% API 函数

%% 启动 Topic 进程
-spec start_link(TopicName :: binary()) -> {ok, pid()} | {error, term()}.

%% 发布单条消息（异步）
-spec publish(TopicPid :: pid(), Body :: binary()) -> ok.

%% 批量发布（异步）
-spec mpub(TopicPid :: pid(), Bodies :: [binary()]) -> ok.

%% 延迟发布
-spec dpub(TopicPid :: pid(), Body :: binary(), DeferMs :: non_neg_integer()) -> ok.

%% 获取 Channel（不存在则创建）
-spec get_channel(TopicPid :: pid(), ChannelName :: binary()) -> {ok, pid()}.

%% 删除 Channel
-spec delete_channel(TopicPid :: pid(), ChannelName :: binary()) -> ok | {error, term()}.

%% 列出所有 Channels
-spec list_channels(TopicPid :: pid()) -> [{binary(), pid()}].

%% 获取统计信息
-spec get_stats(TopicPid :: pid()) -> map().

%% 暂停/恢复 Topic
-spec pause(TopicPid :: pid()) -> ok.
-spec unpause(TopicPid :: pid()) -> ok.

%% 关闭 Topic
-spec stop(TopicPid :: pid()) -> ok.
```

## 配置参数

```erlang
%% Topic 相关配置
{erwind_topic, [
    {max_channels, 100},              %% 每个 Topic 最大 Channel 数
    {max_msg_size, 1048576},          %% 最大消息大小（1MB）
    {default_msg_timeout, 60000},     %% 默认消息超时（毫秒）
    {max_msg_timeout, 900000},        %% 最大消息超时（15分钟）
    {max_msg_defer, 3600000},         %% 最大延迟时间（1小时）
    {memory_queue_limit, 10000}       %% 内存队列消息数限制
]}.
```

## 关键设计决策

### 1. 为什么选择 simple_one_for_one？
- Topic 是动态创建的（根据生产者/消费者请求）
- 每个 Topic 独立生命周期
- 临时 Topic 需要能被完全关闭

### 2. 为什么使用 ETS 注册表？
- 避免遍历监督者子进程（O(N) -> O(1)）
- 读多写少场景，ETS 并发性能优秀
- 进程崩溃时，ETS 条目在 terminate 中清理

### 3. 消息复制的开销
- 每个 Channel 一份消息副本
- 二进制数据在 Erlang 中共享（引用计数）
- 实际复制的只是消息元数据（ID、时间戳等）

### 4. 临时 Topic 处理
- 名称以 `#ephemeral` 结尾
- 无 Channel 时自动关闭
- 不持久化到磁盘
