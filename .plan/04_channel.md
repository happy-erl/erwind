# Channel 模块 (erwind_channel)

## 功能概述

Channel 是 Topic 下的消息分发路径，负责管理消费者订阅，将消息投递给消费者，处理消息确认、重传、超时等机制。

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

## Erlang 实现设计

### 模块结构

```erlang
-module(erwind_channel).
-behaviour(gen_server).

%% API
-export([start_link/2, stop/1, put_message/2, sub/2, unsub/2]).
-export([finish/2, requeue/3, touch/2, update_rdy/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% 消费者记录
-record(consumer, {
    pid :: pid(),
    rdy = 0 :: integer(),           %% Ready 计数
    in_flight = 0 :: integer(),     %% 在途消息数
    msg_timeout :: integer(),       %% 消息超时时间
    inflight_msgs = #{} :: #{binary() => #in_flight_msg{}}
}).

-record(state, {
    topic :: binary(),
    name :: binary(),
    consumers = #{} :: #{pid() => #consumer{}},
    memory_queue :: queue:queue(),
    backend_queue :: pid(),
    in_flight_timer :: reference(),
    
    %% 统计
    depth = 0 :: integer(),         %% 队列深度
    message_count = 0 :: integer(), %% 总消息数
    requeue_count = 0 :: integer(), %% 重入队数
    timeout_count = 0 :: integer(), %% 超时数
    
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

### 核心逻辑

#### 1. 消息入队

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
                    %% 存入队列
                    NewQueue = queue:in(Msg, State#state.memory_queue),
                    {noreply, NewState#state{
                        memory_queue = NewQueue,
                        depth = State#state.depth + 1
                    }}
            end
    end.

%% 尝试投递消息
try_deliver(Msg, State) ->
    %% 找到有 RDY > 0 的消费者
    ConsumersWithRdy = lists:filter(
        fun({_, C}) -> C#consumer.rdy > 0 end,
        maps:to_list(State#state.consumers)
    ),
    
    case ConsumersWithRdy of
        [] ->
            {deferred, State};
        Consumers ->
            %% 轮询选择消费者
            {Pid, Consumer} = select_consumer(Consumers),
            deliver_to_consumer(Pid, Consumer, Msg, State)
    end.

%% 投递给消费者
deliver_to_consumer(Pid, Consumer, Msg, State) ->
    %% 构造消息帧
    MsgFrame = erwind_protocol:encode_message(Msg),
    
    %% 发送
    erwind_connection:send(Pid, MsgFrame),
    
    %% 更新 In-Flight
    Now = erlang:system_time(millisecond),
    InFlightMsg = #in_flight_msg{
        msg = Msg,
        consumer_pid = Pid,
        deliver_time = Now,
        expire_time = Now + Consumer#consumer.msg_timeout
    },
    
    NewConsumer = Consumer#consumer{
        rdy = Consumer#consumer.rdy - 1,
        in_flight = Consumer#consumer.in_flight + 1,
        inflight_msgs = maps:put(Msg#nsq_message.id, InFlightMsg, 
                                  Consumer#consumer.inflight_msgs)
    },
    
    NewConsumers = maps:put(Pid, NewConsumer, State#state.consumers),
    
    {ok, State#state{consumers = NewConsumers}}.
```

#### 2. 消费者订阅

```erlang
%% 订阅
handle_call({sub, ConsumerPid}, _From, State) ->
    %% 监控消费者
    erlang:monitor(process, ConsumerPid),
    
    Consumer = #consumer{
        pid = ConsumerPid,
        msg_timeout = ?DEFAULT_MSG_TIMEOUT
    },
    
    NewConsumers = maps:put(ConsumerPid, Consumer, State#state.consumers),
    
    %% 尝试投递队列中的积压消息
    NewState = try_drain_queue(State#state{consumers = NewConsumers}),
    
    {reply, ok, NewState}.

%% 取消订阅
handle_call({unsub, ConsumerPid}, _From, State) ->
    case maps:get(ConsumerPid, State#state.consumers, undefined) of
        undefined ->
            {reply, {error, not_found}, State};
        Consumer ->
            %% 重新入队所有 In-Flight 消息
            lists:foreach(fun({_, InFlightMsg}) ->
                requeue_msg(InFlightMsg#in_flight_msg.msg, 0, State)
            end, maps:to_list(Consumer#consumer.inflight_msgs)),
            
            NewConsumers = maps:remove(ConsumerPid, State#state.consumers),
            {reply, ok, State#state{consumers = NewConsumers}}
    end.
```

#### 3. 更新 RDY

```erlang
%% 更新消费者 RDY
handle_cast({update_rdy, ConsumerPid, Count}, State) ->
    case maps:get(ConsumerPid, State#state.consumers, undefined) of
        undefined ->
            {noreply, State};
        Consumer ->
            NewConsumer = Consumer#consumer{rdy = Count},
            NewConsumers = maps:put(ConsumerPid, NewConsumer, State#state.consumers),
            
            %% 触发消息投递
            NewState = try_drain_queue(State#state{consumers = NewConsumers}),
            
            {noreply, NewState}
    end.

%% 尝试清空队列
try_drain_queue(State) ->
    case queue:out(State#state.memory_queue) of
        {{value, Msg}, NewQueue} ->
            case try_deliver(Msg, State) of
                {ok, NewState} ->
                    try_drain_queue(NewState#state{memory_queue = NewQueue});
                {deferred, _} ->
                    State
            end;
        {empty, _} ->
            State
    end.
```

#### 4. 消息确认（FIN）

```erlang
%% 消息处理完成
handle_cast({finish, ConsumerPid, MsgId}, State) ->
    case maps:get(ConsumerPid, State#state.consumers, undefined) of
        undefined ->
            {noreply, State};
        Consumer ->
            case maps:take(MsgId, Consumer#consumer.inflight_msgs) of
                {_, NewInFlight} ->
                    NewConsumer = Consumer#consumer{
                        in_flight = Consumer#consumer.in_flight - 1,
                        inflight_msgs = NewInFlight
                    },
                    NewConsumers = maps:put(ConsumerPid, NewConsumer, 
                                             State#state.consumers),
                    {noreply, State#state{consumers = NewConsumers}};
                error ->
                    {noreply, State}
            end
    end.
```

#### 5. 重新入队（REQ）

```erlang
%% 重新入队
handle_cast({requeue, ConsumerPid, MsgId, Timeout}, State) ->
    case maps:get(ConsumerPid, State#state.consumers, undefined) of
        undefined ->
            {noreply, State};
        Consumer ->
            case maps:get(MsgId, Consumer#consumer.inflight_msgs, undefined) of
                undefined ->
                    {noreply, State};
                InFlightMsg ->
                    Msg = InFlightMsg#in_flight_msg.msg,
                    NewMsg = Msg#nsq_message{attempts = Msg#nsq_message.attempts + 1},
                    
                    %% 从 In-Flight 移除
                    NewInFlight = maps:remove(MsgId, Consumer#consumer.inflight_msgs),
                    NewConsumer = Consumer#consumer{
                        in_flight = Consumer#consumer.in_flight - 1,
                        inflight_msgs = NewInFlight
                    },
                    NewConsumers = maps:put(ConsumerPid, NewConsumer, 
                                             State#state.consumers),
                    
                    %% 延迟或直接重新入队
                    case Timeout of
                        0 ->
                            %% 立即重新入队
                            handle_cast({put_message, NewMsg}, 
                                       State#state{consumers = NewConsumers});
                        _ ->
                            %% 延迟重新入队
                            erlang:send_after(Timeout, self(), 
                                             {deferred_requeue, NewMsg}),
                            {noreply, State#state{consumers = NewConsumers}}
                    end
            end
    end.

%% 延迟重新入队处理
handle_info({deferred_requeue, Msg}, State) ->
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

### 依赖的模块
- `erwind_backend_queue` - 磁盘队列持久化
- `erwind_protocol` - 消息编码
- `erwind_connection` - 发送消息给消费者
- `erwind_stats` - 统计信息

### 被依赖的模块
- `erwind_topic` - Topic 创建 Channel
- `erwind_channel_sup` - 监督者启动

## 接口定义

```erlang
%% 启动 Channel
-spec start_link(Topic :: binary(), Channel :: binary()) -> {ok, pid()}.

%% 消息入队
-spec put_message(ChannelPid :: pid(), Msg :: #nsq_message{}) -> ok.

%% 消费者订阅
-spec sub(ChannelPid :: pid(), ConsumerPid :: pid()) -> ok | {error, term()}.

%% 取消订阅
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

%% 获取统计
-spec get_stats(ChannelPid :: pid()) -> map().
```

## 配置参数

```erlang
{erwind_channel, [
    {max_consumers, 100},             %% 每个 Channel 最大消费者数
    {memory_queue_size, 10000},       %% 内存队列大小
    {msg_timeout, 60000},             %% 消息超时（毫秒）
    {max_msg_timeout, 900000},        %% 最大消息超时
    {max_msg_attempts, 5},            %% 最大投递次数
    {timeout_check_interval, 5000},   %% 超时检查间隔（毫秒）
    {output_buffer_size, 16384},      %% 输出缓冲区大小
    {output_buffer_timeout, 250}      %% 输出缓冲超时（毫秒）
]}.
```
