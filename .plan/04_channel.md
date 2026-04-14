# Channel 模块 (erwind_channel)

## 功能概述

Channel 是 Topic 下的消息分发路径，负责协调消息投递、消费者管理和消息确认。从 v2 版本开始，Channel 的核心功能已拆分为多个独立模块：

```
erwind_channel (协调器)
├── erwind_consumer_manager (消费者管理) [13_consumer_manager.md]
├── erwind_memory_queue (内存队列)
├── erwind_inflight_tracker (在途跟踪) [14_inflight_tracker.md]
└── erwind_delayed_queue (延迟队列) [15_delayed_queue.md]
```

Channel 现在主要负责：
1. **协调消息投递流程**
2. **管理子模块生命周期**
3. **与 Topic 和 Consumer 交互**

## 原理详解

### Channel 的核心职责

1. **消费者管理**：订阅/取消订阅消费者连接
2. **消息队列**：维护待投递消息队列（内存 + 磁盘）
3. **消息投递**：将消息推送给消费者（根据 RDY 流量控制）
4. **In-Flight 管理**：跟踪已投递但未确认的消息
5. **超时重传**：消息超时后自动重新入队
6. **延迟队列**：支持延迟投递的消息

### 消费者模型

```
                    +----------------+
                    |    Channel     |
                    |   (内存队列)    |
                    +--------+-------+
                             |
         +-------------------+-------------------+
         |                   |                   |
+--------v--------+ +-------v--------+ +-------v--------+
|  Consumer A     | |  Consumer B    | |  Consumer C    |
|   RDY: 100      | |   RDY: 50      | |   RDY: 0       |
|                 | |                | |   (暂停接收)   |
|  In-Flight: 10  | |  In-Flight: 45 | |  In-Flight: 0  |
+-----------------+ +----------------+ +----------------+
```

- 消息在 Channel 内**竞争消费**：每个消息只投递给一个消费者
- RDY 机制实现背压：消费者控制接收速率
- In-Flight 窗口：未确认消息数量限制

### 消息生命周期

```
+-----------+    +------------+    +-------------+    +----------+
|  Memory   | -> |  Channel   | -> |  In-Flight  | -> |  FIN/REQ |
|  Queue    |    |  Queue     |    |  (消费者)   |    |          |
+-----------+    +------------+    +-------------+    +----------+
                        |                |
                        v                v (超时)
                   +-----------+    +------------+
                   |   Disk    |    |  Deferred  |
                   |   Queue   |    |  Queue     |
                   +-----------+    +------------+
```

1. 消息从 Topic 进入 Channel 队列
2. 根据 RDY 投递给消费者，放入 In-Flight
3. 消费者处理完成发送 FIN，消息删除
4. 或发送 REQ，消息重新入队（可延迟）
5. 超时未确认，自动重新入队

### In-Flight 管理

```erlang
%% In-Flight 消息结构
-record(in_flight_msg, {
    msg :: #nsq_message{},
    consumer_pid :: pid(),       %% 投递给的消费者
    deliver_time :: integer(),   %% 投递时间（毫秒）
    expire_time :: integer()     %% 超时时间（毫秒）
}).

%% In-Flight 表（ETS 或 Map）
%% Key: Message ID, Value: #in_flight_msg{}
```

超时检查策略：
- 定时扫描（每 N 毫秒）
- 优先队列/最小堆优化
- 超时消息重新入队

## 与新增模块的协作

### 架构拆分

```
┌─────────────────────────────────────────────────────────────┐
│                    erwind_channel                            │
│                   (协调器/门面)                              │
└──────────────┬────────────────┬────────────────┬────────────┘
               │                │                │
    ┌──────────v────────┐ ┌────v─────────┐ ┌────v──────────┐
    │ consumer_manager  │ │ inflight_    │ │ delayed_queue │
    │                   │ │   tracker    │ │               │
    │ - 注册/注销       │ │              │ │ - 延迟调度    │
    │ - 负载均衡        │ │ - 超时检测   │ │ - 时间轮      │
    │ - RDY 管理        │ │ - ACK 处理   │ │ - 到期触发    │
    └───────────────────┘ └──────────────┘ └───────────────┘
```

### 消息投递流程（新架构）

```
erwind_channel:put_message(Msg)
    │
    ├───> erwind_consumer_manager:select_consumer()
    │         │
    │         └───> 负载均衡算法选择消费者
    │
    ├───> erwind_connection:send(Consumer, Msg)
    │
    └───> erwind_inflight_tracker:track(MsgId, Consumer, Timeout)
              │
              └───> 启动超时检测

[消费者处理...]

erwind_channel:finish(MsgId)
    │
    └───> erwind_inflight_tracker:ack(MsgId)
              │
              └───> 清除超时检测
```

### 延迟消息流程

```
erwind_channel:requeue(MsgId, DelayMs)
    │
    ├───> erwind_inflight_tracker:requeue(MsgId) [取出消息]
    │
    └───> erwind_delayed_queue:schedule(Msg, DelayMs)
              │
              └───> 时间轮调度

[延迟到期...]

erwind_delayed_queue ───> erwind_channel:put_message(Msg) [重新投递]
```

## Erlang 实现设计

### 模块结构（v2 - 拆分后）

```erlang
-module(erwind_channel).
-behaviour(gen_server).

%% API
-export([start_link/2, stop/1, put_message/2, sub/2, unsub/2]).
-export([finish/2, requeue/3, touch/2, update_rdy/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {
    topic :: binary(),
    name :: binary(),
    
    %% 子模块 PIDs
    consumer_manager :: pid(),      %% 消费者管理器 [13_consumer_manager.md]
    inflight_tracker :: pid(),      %% 在途跟踪器 [14_inflight_tracker.md]
    memory_queue :: pid(),          %% 内存队列
    delayed_queue :: pid(),         %% 延迟队列 [15_delayed_queue.md]
    backend_queue :: pid(),         %% 后端队列 [05_backend_queue.md]
    
    %% 统计（聚合子模块数据）
    depth = 0 :: integer(),
    message_count = 0 :: integer(),
    
    %% 配置
    paused = false :: boolean(),
    ephemeral = false :: boolean()
}).
```

### 监督者配置

```erlang
%% erwind_channel_sup.erl
%% 每个 Topic 有一个 Channel Sup，动态创建 Channel

init([TopicName]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 100,
        period => 10
    },
    ChannelSpec = #{
        id => erwind_channel,
        start => {erwind_channel, start_link, [TopicName]},
        restart => temporary,
        shutdown => 5000,
        type => worker,
        modules => [erwind_channel]
    },
    {ok, {SupFlags, [ChannelSpec]}}.
```

### 核心逻辑（调用子模块）

#### 1. 初始化（启动子模块）

```erlang
init([Topic, Channel]) ->
    process_flag(trap_exit, true),
    
    %% 启动子模块
    {ok, ConsumerMgr} = erwind_consumer_manager:start_link(Topic, Channel),
    {ok, InflightTracker} = erwind_inflight_tracker:start_link(Topic, Channel),
    {ok, DelayedQueue} = erwind_delayed_queue:start_link(Topic, Channel),
    {ok, MemoryQueue} = erwind_memory_queue:start_link(),
    {ok, BackendQueue} = erwind_backend_queue:start_link(Topic, Channel),
    
    {ok, #state{
        topic = Topic,
        name = Channel,
        consumer_manager = ConsumerMgr,
        inflight_tracker = InflightTracker,
        memory_queue = MemoryQueue,
        delayed_queue = DelayedQueue,
        backend_queue = BackendQueue
    }}.
```

#### 2. 消息入队（新架构）

```erlang
%% 从 Topic 接收消息
handle_cast({put_message, Msg}, State) ->
    case State#state.paused of
        true ->
            %% 直接写入磁盘队列
            erwind_backend_queue:put(State#state.backend_queue, Msg),
            {noreply, State#state{depth = State#state.depth + 1}};
        false ->
            %% 尝试投递给有 RDY 的消费者
            case try_deliver(Msg, State) of
                {ok, NewState} ->
                    {noreply, NewState};
                {deferred, NewState} ->
                    %% 存入内存队列
                    erwind_memory_queue:in(State#state.memory_queue, Msg),
                    {noreply, NewState#state{
                        depth = NewState#state.depth + 1
                    }}
            end
    end.

%% 尝试投递消息（调用 consumer_manager）
try_deliver(Msg, State) ->
    case erwind_consumer_manager:select_consumer(State#state.consumer_manager) of
        empty ->
            {deferred, State};
        {ok, ConsumerPid, ConsumerInfo} ->
            deliver_to_consumer(ConsumerPid, ConsumerInfo, Msg, State)
    end.

%% 投递给消费者
deliver_to_consumer(Pid, ConsumerInfo, Msg, State) ->
    %% 构造消息帧
    MsgFrame = erwind_protocol:encode_message(Msg),
    
    %% 发送给消费者连接进程
    erwind_connection:send(Pid, MsgFrame),
    
    %% 更新消费者 RDY (调用 consumer_manager)
    erwind_consumer_manager:incr_inflight(State#state.consumer_manager, Pid),
    
    %% 跟踪 In-Flight (调用 inflight_tracker)
    Timeout = ConsumerInfo#consumer_info.msg_timeout,
    erwind_inflight_tracker:track(
        State#state.inflight_tracker,
        Msg#nsq_message.id,
        Msg,
        Pid,
        Timeout
    ),
    
    {ok, State}.
```

#### 2. 消费者订阅（调用 consumer_manager）

```erlang
%% 订阅
handle_call({sub, ConsumerPid, Caps}, _From, State) ->
    %% 注册到 consumer_manager
    ok = erwind_consumer_manager:register_consumer(
        State#state.consumer_manager,
        ConsumerPid,
        Caps
    ),
    
    %% 尝试投递队列中的积压消息
    NewState = try_drain_queue(State),
    
    {reply, ok, NewState}.

%% 取消订阅
handle_call({unsub, ConsumerPid}, _From, State) ->
    %% 从 consumer_manager 注销
    ok = erwind_consumer_manager:unregister_consumer(
        State#state.consumer_manager,
        ConsumerPid
    ),
    
    %% 获取该消费者的 In-Flight 消息
    InflightMsgs = erwind_inflight_tracker:get_by_consumer(
        State#state.inflight_tracker,
        ConsumerPid
    ),
    
    %% 重新入队所有 In-Flight 消息
    lists:foreach(fun(Msg) ->
        erwind_inflight_tracker:ack(State#state.inflight_tracker, 
                                     Msg#nsq_message.id),
        erwind_memory_queue:in(State#state.memory_queue, Msg)
    end, InflightMsgs),
    
    {reply, ok, State}.
```

#### 3. 更新 RDY（调用 consumer_manager）

```erlang
%% 更新消费者 RDY
handle_cast({update_rdy, ConsumerPid, Count}, State) ->
    %% 更新 consumer_manager
    ok = erwind_consumer_manager:update_rdy(
        State#state.consumer_manager,
        ConsumerPid,
        Count
    ),
    
    %% 触发消息投递
    NewState = try_drain_queue(State),
    
    {noreply, NewState}.

%% 尝试清空队列（从 memory_queue）
try_drain_queue(State) ->
    case erwind_memory_queue:out(State#state.memory_queue) of
        {ok, Msg} ->
            case try_deliver(Msg, State) of
                {ok, NewState} ->
                    try_drain_queue(NewState);
                {deferred, _} ->
                    %% 投递失败，放回队列头部
                    erwind_memory_queue:push_front(State#state.memory_queue, Msg),
                    State
            end;
        empty ->
            State
    end.
```

#### 4. 消息确认（FIN）- 调用 inflight_tracker

```erlang
%% 消息处理完成
handle_cast({finish, ConsumerPid, MsgId}, State) ->
    %% 确认 In-Flight (调用 inflight_tracker)
    case erwind_inflight_tracker:ack(State#state.inflight_tracker, MsgId) of
        ok ->
            %% 更新消费者统计 (调用 consumer_manager)
            erwind_consumer_manager:decr_inflight(
                State#state.consumer_manager,
                ConsumerPid
            ),
            
            {noreply, State#state{
                depth = State#state.depth - 1,
                message_count = State#state.message_count + 1
            }};
        {error, not_found} ->
            {noreply, State}
    end.
```

#### 5. 重新入队（REQ）- 调用 inflight_tracker 和 delayed_queue

```erlang
%% 重新入队
handle_cast({requeue, ConsumerPid, MsgId, Timeout}, State) ->
    %% 从 inflight_tracker 取出消息
    case erwind_inflight_tracker:requeue(
        State#state.inflight_tracker,
        MsgId,
        Timeout
    ) of
        {ok, Msg} ->
            %% 更新消费者统计
            erwind_consumer_manager:decr_inflight(
                State#state.consumer_manager,
                ConsumerPid
            ),
            
            NewMsg = Msg#nsq_message{
                attempts = Msg#nsq_message.attempts + 1
            },
            
            %% 延迟或直接重新入队
            case Timeout of
                0 ->
                    %% 立即重新入队
                    handle_cast({put_message, NewMsg}, State);
                _ ->
                    %% 延迟重新入队 (调用 delayed_queue)
                    erwind_delayed_queue:schedule(
                        State#state.delayed_queue,
                        NewMsg,
                        Timeout
                    ),
                    {noreply, State#state{
                        requeue_count = State#state.requeue_count + 1
                    }}
            end;
        {error, not_found} ->
            {noreply, State}
    end.

%% 延迟队列到期回调（delayed_queue 触发）
handle_cast({delayed_delivery, Msg}, State) ->
    %% 重新投递延迟消息
    handle_cast({put_message, Msg}, State).
```

#### 6. 超时检查

```erlang
%% 启动定时器检查超时
init([]) ->
    TimerRef = erlang:send_after(?TIMEOUT_CHECK_INTERVAL, self(), check_timeouts),
    {ok, #state{in_flight_timer = TimerRef}}.

%% 检查超时消息
handle_info(check_timeouts, State) ->
    Now = erlang:system_time(millisecond),
    
    %% 遍历所有消费者的 In-Flight 消息
    {NewConsumers, TimeoutCount} = maps:fold(fun(Pid, Consumer, {Cs, Count}) ->
        {NewInFlight, Expired} = maps:fold(fun(MsgId, IFM, {Active, Exp}) ->
            case IFM#in_flight_msg.expire_time =< Now of
                true ->
                    %% 超时，重新入队
                    requeue_msg(IFM#in_flight_msg.msg, 0, State),
                    {Active, Exp + 1};
                false ->
                    {maps:put(MsgId, IFM, Active), Exp}
            end
        end, {#{}, 0}, Consumer#consumer.inflight_msgs),
        
        NewConsumer = Consumer#consumer{
            in_flight = map_size(NewInFlight),
            inflight_msgs = NewInFlight
        },
        {maps:put(Pid, NewConsumer, Cs), Count + Expired}
    end, {#{}, 0}, State#state.consumers),
    
    %% 重启定时器
    NewTimer = erlang:send_after(?TIMEOUT_CHECK_INTERVAL, self(), check_timeouts),
    
    {noreply, State#state{
        consumers = NewConsumers,
        in_flight_timer = NewTimer,
        timeout_count = State#state.timeout_count + TimeoutCount
    }}.
```

## 依赖关系

### 依赖的模块（新增）
- `erwind_consumer_manager` - 消费者管理 [13_consumer_manager.md]
- `erwind_inflight_tracker` - 在途消息跟踪 [14_inflight_tracker.md]
- `erwind_delayed_queue` - 延迟队列 [15_delayed_queue.md]
- `erwind_memory_queue` - 内存队列
- `erwind_backend_queue` - 后端队列 [05_backend_queue.md]
- `erwind_protocol` - 消息编码 [02_protocol.md]
- `erwind_connection` - 发送消息给消费者
- `erwind_stats` - 统计信息 [08_stats.md]

### 被依赖的模块
- `erwind_topic` - Topic 创建 Channel [03_topic.md]
- `erwind_channel_sup` - 监督者启动 [09_supervision_tree.md]

### 依赖关系图

```
erwind_channel
    ├── erwind_consumer_manager (消费者管理)
    ├── erwind_inflight_tracker (在途跟踪)
    ├── erwind_delayed_queue (延迟调度)
    ├── erwind_memory_queue (内存队列)
    ├── erwind_backend_queue (磁盘队列)
    ├── erwind_protocol (编解码)
    └── erwind_stats (统计)
```

## 接口定义

```erlang
%% 启动 Channel
-spec start_link(Topic :: binary(), Channel :: binary()) -> {ok, pid()}.

%% 消息入队
-spec put_message(ChannelPid :: pid(), Msg :: #nsq_message{}) -> ok.

%% 消费者订阅
-spec sub(ChannelPid :: pid(), ConsumerPid :: pid(), Caps :: map()) -> ok | {error, term()}.
-spec unsub(ChannelPid :: pid(), ConsumerPid :: pid()) -> ok.

%% 更新 RDY
-spec update_rdy(ChannelPid :: pid(), ConsumerPid :: pid(), Count :: integer()) -> ok.

%% 消息确认
-spec finish(ChannelPid :: pid(), ConsumerPid :: pid(), MsgId :: binary()) -> ok.

%% 重新入队
-spec requeue(ChannelPid :: pid(), ConsumerPid :: pid(), MsgId :: binary(), 
              Timeout :: integer()) -> ok.

%% Touch（延长超时）
-spec touch(ChannelPid :: pid(), ConsumerPid :: pid(), MsgId :: binary()) -> ok.

%% 获取统计（聚合各子模块）
-spec get_stats(ChannelPid :: pid()) -> #{
    depth => integer(),
    message_count => integer(),
    consumer_count => integer(),
    inflight_count => integer(),
    delayed_count => integer()
}.
```

## 配置参数

```erlang
{erwind_channel, [
    %% Channel 基础配置
    {max_consumers, 100},             %% 每个 Channel 最大消费者数
    {paused, false},                  %% 默认暂停状态
    {ephemeral, false},               %% 是否临时 Channel
    
    %% 子模块配置传递
    {consumer_manager_config, [
        {balance_strategy, round_robin},
        {health_check_interval, 30000}
    ]},
    
    {inflight_tracker_config, [
        {check_interval, 5000},
        {max_retry_count, 5}
    ]},
    
    {delayed_queue_config, [
        {tick_interval, 1},
        {max_delay_ms, 3600000}
    ]},
    
    {memory_queue_config, [
        {max_size, 10000}
    ]}
]}.
```

## 版本历史

| 版本 | 变更 | 说明 |
|------|------|------|
| v1 | 单体实现 | 消费者管理、In-Flight、延迟队列均在 Channel 内 |
| v2 | 模块拆分 | 拆分为 consumer_manager、inflight_tracker、delayed_queue |

## 相关文档

- [13_consumer_manager.md](13_consumer_manager.md) - 消费者管理器
- [14_inflight_tracker.md](14_inflight_tracker.md) - 在途消息跟踪器
- [15_delayed_queue.md](15_delayed_queue.md) - 延迟队列
