# 消费者管理模块 (erwind_consumer_manager)

## 功能概述

消费者管理器负责集中管理 Channel 下的所有消费者连接，实现负载均衡、健康检查和资源清理。它是从原 `erwind_channel` 中拆分出来的独立模块。

## 为什么需要拆分

### 原设计的问题

```erlang
%% 原 erwind_channel 中的消费者管理
-record(state, {
    consumers = #{} :: #{pid() => #consumer{}},  %% 直接管理consumers map
    %% ... 其他10+个字段
}).
```

问题：
1. Channel 负责消息队列 + 消费者管理 + In-Flight跟踪，职责过重
2. 消费者负载均衡算法难以独立测试
3. 健康检查逻辑和 Channel 状态机耦合

### 新设计优势

```
erwind_channel (协调者)
    │
    ├── erwind_consumer_manager (消费者生命周期)
    ├── erwind_inflight_tracker (在途消息)
    ├── erwind_memory_queue (消息队列)
    └── erwind_delayed_queue (延迟消息)
```

## 核心职责

1. **消费者注册/注销**
2. **负载均衡算法**（轮询/一致性哈希/最少连接）
3. **健康检查**
4. **RDY 管理**
5. **统计收集**

## 数据结构

```erlang
-module(erwind_consumer_manager).
-behaviour(gen_server).

%% 消费者信息记录
-record(consumer_info, {
    pid :: pid(),
    rdy = 0 :: integer(),           %% Ready 计数
    in_flight = 0 :: integer(),     %% 在途消息数
    msg_timeout :: integer(),       %% 消息超时时间
    capabilities = #{} :: map(),    %% 客户端能力
    last_active :: integer(),       %% 最后活跃时间
    health = healthy :: healthy | unhealthy,
    connect_time :: integer()       %% 连接时间
}).

%% 负载均衡状态
-record(balance_state, {
    strategy :: balance_strategy(),
    current_index = 0 :: integer(), %% 轮询索引
    hash_ring :: any()              %% 一致性哈希环
}).

%% 管理器状态
-record(state, {
    channel :: binary(),
    topic :: binary(),
    consumers = #{} :: #{pid() => #consumer_info{}},
    balance_state :: #balance_state{},
    
    %% 统计
    total_consumers = 0 :: integer(),
    healthy_consumers = 0 :: integer(),
    total_rdy = 0 :: integer(),
    total_in_flight = 0 :: integer()
}).

%% 负载均衡策略
-type balance_strategy() :: round_robin | consistent_hash | least_loaded | random.
```

## API 接口

```erlang
%% 启动
-spec start_link(Topic :: binary(), Channel :: binary()) -> {ok, pid()}.

%% 消费者生命周期
-spec register_consumer(pid(), ConsumerPid :: pid(), Capabilities :: map()) -> ok.
-spec unregister_consumer(pid(), ConsumerPid :: pid()) -> ok.

%% RDY 管理
-spec update_rdy(pid(), ConsumerPid :: pid(), Count :: integer()) -> ok.
-spec get_total_rdy(pid()) -> integer().

%% 负载均衡
-spec select_consumer(pid()) -> {ok, pid(), #consumer_info{}} | empty.
-spec set_strategy(pid(), balance_strategy()) -> ok.

%% In-Flight 计数
-spec incr_inflight(pid(), ConsumerPid :: pid()) -> ok.
-spec decr_inflight(pid(), ConsumerPid :: pid()) -> ok.

%% 健康检查
-spec mark_active(pid(), ConsumerPid :: pid()) -> ok.
-spec get_healthy_consumers(pid()) -> [pid()].

%% 统计
-spec get_stats(pid()) -> map().
```

## 核心逻辑

### 1. 消费者注册

```erlang
%% 新消费者连接
handle_call({register, Pid, Caps}, _From, State) ->
    %% 监控消费者进程
    erlang:monitor(process, Pid),
    
    Consumer = #consumer_info{
        pid = Pid,
        rdy = 0,
        in_flight = 0,
        msg_timeout = maps:get(msg_timeout, Caps, ?DEFAULT_MSG_TIMEOUT),
        capabilities = Caps,
        last_active = erlang:system_time(millisecond),
        health = healthy,
        connect_time = erlang:system_time(millisecond)
    },
    
    NewConsumers = maps:put(Pid, Consumer, State#state.consumers),
    
    %% 更新统计
    NewState = State#state{
        consumers = NewConsumers,
        total_consumers = State#state.total_consumers + 1,
        healthy_consumers = State#state.healthy_consumers + 1
    },
    
    %% 通知 Channel 有新消费者
    notify_channel(new_consumer, Pid),
    
    {reply, ok, NewState}.
```

### 2. 负载均衡算法

#### 轮询 (Round Robin)

```erlang
select_consumer(#state{strategy = round_robin} = State) ->
    Healthy = get_healthy_consumers(State),
    case Healthy of
        [] -> empty;
        _ ->
            Index = State#state.current_index rem length(Healthy),
            ConsumerPid = lists:nth(Index + 1, Healthy),
            Consumer = maps:get(ConsumerPid, State#state.consumers),
            %% 检查 RDY
            case Consumer#consumer_info.rdy > 0 of
                true ->
                    {ok, ConsumerPid, Consumer};
                false ->
                    %% 找下一个有 RDY 的消费者
                    find_next_rdy(Healthy, Index, State)
            end
    end.

find_next_rdy(Healthy, StartIndex, State) ->
    Count = length(Healthy),
    find_next_rdy(Healthy, StartIndex, State, Count, 0).

find_next_rdy(_Healthy, _StartIndex, _State, _Count, _Count) ->
    empty;
find_next_rdy(Healthy, StartIndex, State, Count, Tried) ->
    Index = (StartIndex + Tried + 1) rem Count,
    ConsumerPid = lists:nth(Index + 1, Healthy),
    Consumer = maps:get(ConsumerPid, State#state.consumers),
    case Consumer#consumer_info.rdy > 0 of
        true -> {ok, ConsumerPid, Consumer};
        false -> find_next_rdy(Healthy, StartIndex, State, Count, Tried + 1)
    end.
```

#### 一致性哈希 (Consistent Hash)

```erlang
%% 初始化哈希环
init_consistent_hash() ->
    %% 使用 MD5 计算消费者 hash
    #balance_state{
        strategy = consistent_hash,
        hash_ring = gb_trees:empty()
    }.

%% 添加消费者到哈希环
add_to_hash_ring(State, ConsumerPid) ->
    %% 虚拟节点数：每个消费者对应 100 个虚拟节点
    VirtualNodes = 100,
    Ring = lists:foldl(fun(N, Acc) ->
        Key = crypto:hash(md5, term_to_binary({ConsumerPid, N})),
        gb_trees:insert(Key, ConsumerPid, Acc)
    end, State#balance_state.hash_ring, lists:seq(1, VirtualNodes)),
    
    State#state{
        balance_state = State#state.balance_state#balance_state{
            hash_ring = Ring
        }
    }.

%% 基于消息 ID 选择消费者
select_consumer(#state{strategy = consistent_hash} = State, MsgId) ->
    Hash = crypto:hash(md5, MsgId),
    Ring = State#balance_state.hash_ring,
    
    %% 找到第一个 >= Hash 的节点
    case gb_trees:lookup(Hash, Ring) of
        {value, ConsumerPid} ->
            Consumer = maps:get(ConsumerPid, State#state.consumers),
            {ok, ConsumerPid, Consumer};
        none ->
            %% 返回环的第一个节点
            case gb_trees:smallest(Ring) of
                {_, ConsumerPid} ->
                    Consumer = maps:get(ConsumerPid, State#state.consumers),
                    {ok, ConsumerPid, Consumer};
                _ -> empty
            end
    end.
```

#### 最少负载 (Least Loaded)

```erlang
select_consumer(#state{strategy = least_loaded} = State) ->
    Healthy = get_healthy_consumers(State),
    case Healthy of
        [] -> empty;
        _ ->
            %% 选择在途消息最少的消费者
            ConsumerPid = lists:min_by(fun(Pid) ->
                C = maps:get(Pid, State#state.consumers),
                C#consumer_info.in_flight
            end, Healthy),
            Consumer = maps:get(ConsumerPid, State#state.consumers),
            {ok, ConsumerPid, Consumer}
    end.
```

### 3. 健康检查

```erlang
%% 启动健康检查定时器
init([]) ->
    erlang:send_after(?HEALTH_CHECK_INTERVAL, self(), health_check),
    {ok, #state{}}.

%% 健康检查逻辑
handle_info(health_check, State) ->
    Now = erlang:system_time(millisecond),
    
    {NewConsumers, HealthyCount} = maps:fold(fun(Pid, Consumer, {Acc, Count}) ->
        LastActive = Consumer#consumer_info.last_active,
        Timeout = Consumer#consumer_info.msg_timeout * 2,
        
        %% 检查是否超时未活跃
        NewHealth = case Now - LastActive > Timeout of
            true -> unhealthy;
            false -> healthy
        end,
        
        NewConsumer = Consumer#consumer_info{health = NewHealth},
        NewCount = case NewHealth of
            healthy -> Count + 1;
            unhealthy -> Count
        end,
        
        {maps:put(Pid, NewConsumer, Acc), NewCount}
    end, {#{}, 0}, State#state.consumers),
    
    %% 重启定时器
    erlang:send_after(?HEALTH_CHECK_INTERVAL, self(), health_check),
    
    {noreply, State#state{
        consumers = NewConsumers,
        healthy_consumers = HealthyCount
    }}.
```

### 4. 消费者退出处理

```erlang
handle_info({'DOWN', _Ref, process, Pid, _Reason}, State) ->
    case maps:get(Pid, State#state.consumers, undefined) of
        undefined ->
            {noreply, State};
        Consumer ->
            %% 清理消费者
            NewConsumers = maps:remove(Pid, State#state.consumers),
            
            %% 更新统计
            HealthyDelta = case Consumer#consumer_info.health of
                healthy -> -1;
                unhealthy -> 0
            end,
            
            NewState = State#state{
                consumers = NewConsumers,
                total_consumers = State#state.total_consumers - 1,
                healthy_consumers = State#state.healthy_consumers + HealthyDelta,
                total_rdy = State#state.total_rdy - Consumer#consumer_info.rdy,
                total_in_flight = State#state.total_in_flight - Consumer#consumer_info.in_flight
            },
            
            %% 通知 Channel 消费者退出
            notify_channel(consumer_down, Pid, Consumer#consumer_info.in_flight),
            
            {noreply, NewState}
    end.
```

## 与 Channel 的协作

```
erwind_channel                           erwind_consumer_manager
     │                                           │
     │──subscribe(ConsumerPid)──────────────────>│
     │                                           │──register_consumer()
     │                                           │
     │<─────────────────────────────────────ok──│
     │                                           │
     │──try_deliver()──────────────────────────>│
     │                                           │──select_consumer()
     │<────────────────────{ok, ConsumerPid}────│
     │                                           │
     │──send_message(Msg, ConsumerPid)─────────>│
     │                                           │──decr_rdy()
     │                                           │──incr_inflight()
     │                                           │
     │<─────────────────────────────────────ok──│
     │                                           │
     │──on_message_ack(MsgId, ConsumerPid)─────>│
     │                                           │──decr_inflight()
```

## 依赖关系

### 依赖的模块
- `erwind_stats` - 上报消费者统计
- `erwind_channel` - 通知消费者状态变更

### 被依赖的模块
- `erwind_channel` - 调用消费者选择

## 配置参数

```erlang
{erwind_consumer_manager, [
    {balance_strategy, round_robin},      %% 负载均衡策略
    {health_check_interval, 30000},       %% 健康检查间隔（毫秒）
    {consumer_timeout_multiplier, 2},     %% 超时倍数
    {max_consumers_per_channel, 100},     %% 每个 Channel 最大消费者数
    {consistent_hash_virtual_nodes, 100}  %% 一致性哈希虚拟节点数
]}.
```

## 性能优化

1. **ETS 存储**：高并发场景下，consumers map 可替换为 ETS
2. **快照读取**：统计信息使用 ETS counters
3. **批量选择**：支持一次选择多个消费者

```erlang
%% 批量选择消费者（用于批量投递）
-spec select_consumers(pid(), Count :: integer()) -> [pid()].
select_consumers(Pid, Count) ->
    gen_server:call(Pid, {select_consumers, Count}).
```
