# 在途消息跟踪模块 (erwind_inflight_tracker)

## 功能概述

在途消息跟踪器负责管理已投递但未确认的消息，实现超时检测、重传调度和消息确认。这是从原 `erwind_channel` 中拆分出来的关键模块。

## 为什么需要独立模块

### 原设计问题

```erlang
%% 原 erwind_channel 中的 In-Flight 管理
-record(state, {
    consumers = #{} :: #{pid() => #consumer{
        inflight_msgs = #{} :: #{binary() => #in_flight_msg{}}
    }},
    %% In-Flight 分散在各个消费者的 map 中
}).

%% 问题：
%% 1. 超时检测需要遍历所有消费者的所有消息 - O(N*M)
%% 2. 无法使用 ETS 优化并发性能
%% 3. 重传逻辑和 Channel 状态机耦合
```

### 新设计优势

```erlang
%% 独立 tracker，使用 ETS 存储
-record(state, {
    table :: ets:tid(),           %% ETS 表存储所有 In-Flight
    expire_heap :: gb_tree(),     %% 按过期时间排序的堆
    timer_ref :: reference()      %% 下次检查定时器
}).
```

优势：
- O(1) 消息查找
- O(log N) 超时检测（使用最小堆）
- 独立进程，不影响 Channel 主循环

## 数据结构

```erlang
-module(erwind_inflight_tracker).
-behaviour(gen_server).

%% 在途消息记录
-record(inflight_entry, {
    msg_id :: binary(),
    msg :: #nsq_message{},
    consumer_pid :: pid(),
    deliver_time :: integer(),      %% 投递时间戳
    expire_time :: integer(),       %% 过期时间戳
    retry_count = 0 :: integer(),   %% 重试次数
    touched = false :: boolean()    %% 是否被 touch 延长
}).

%% 状态
-record(state, {
    table :: ets:tid(),             %% ETS: msg_id -> #inflight_entry{}
    consumer_table :: ets:tid(),    %% ETS: consumer_pid -> [msg_id]
    expire_heap :: gb_trees:tree(), %% 按 expire_time 排序的最小堆
    timer_ref :: reference() | undefined,
    check_interval :: integer()
}).
```

## API 接口

```erlang
%% 启动
-spec start_link(Topic :: binary(), Channel :: binary()) -> {ok, pid()}.

%% 消息跟踪
-spec track(pid(), binary(), #nsq_message{}, pid(), Timeout :: integer()) -> ok.
-spec track_batch(pid(), [{binary(), #nsq_message{}, pid(), integer()}]) -> ok.

%% 消息确认
-spec ack(pid(), binary()) -> ok | {error, not_found}.
-spec ack_batch(pid(), [binary()]) -> {ok, integer()}.

%% 重新入队
-spec requeue(pid(), binary(), Delay :: integer()) -> 
    {ok, #nsq_message{}} | {error, not_found}.

%% Touch 延长超时
-spec touch(pid(), binary(), ExtendMs :: integer()) -> ok | {error, not_found}.

%% 查询
-spec get_inflight_count(pid()) -> integer().
-spec get_inflight_count(pid(), ConsumerPid :: pid()) -> integer().
-spec get_expired_msgs(pid(), MaxCount :: integer()) -> [#nsq_message{}].

%% 统计
-spec get_stats(pid()) -> #{
    total => integer(),
    by_consumer => #{pid() => integer()},
    avg_retry => float()
}.
```

## 核心逻辑

### 1. 消息跟踪 (Track)

```erlang
%% 单条消息跟踪
handle_call({track, MsgId, Msg, ConsumerPid, Timeout}, _From, State) ->
    Now = erlang:system_time(millisecond),
    ExpireTime = Now + Timeout,
    
    Entry = #inflight_entry{
        msg_id = MsgId,
        msg = Msg,
        consumer_pid = ConsumerPid,
        deliver_time = Now,
        expire_time = ExpireTime,
        retry_count = 0
    },
    
    %% 插入 ETS
    ets:insert(State#state.table, Entry),
    
    %% 更新消费者索引
    ets:update_counter(State#state.consumer_table, ConsumerPid, 
                       {2, 1}, {ConsumerPid, 0}),
    
    %% 插入过期堆
    NewHeap = gb_trees:insert({ExpireTime, MsgId}, MsgId, State#state.expire_heap),
    
    %% 检查是否需要调整定时器
    NewTimer = maybe_adjust_timer(State#state.timer_ref, ExpireTime),
    
    {reply, ok, State#state{
        expire_heap = NewHeap,
        timer_ref = NewTimer
    }}.

%% 批量跟踪（优化批量投递）
handle_call({track_batch, Entries}, _From, State) ->
    Now = erlang:system_time(millisecond),
    
    lists:foreach(fun({MsgId, Msg, ConsumerPid, Timeout}) ->
        ExpireTime = Now + Timeout,
        Entry = #inflight_entry{
            msg_id = MsgId,
            msg = Msg,
            consumer_pid = ConsumerPid,
            deliver_time = Now,
            expire_time = ExpireTime
        },
        ets:insert(State#state.table, Entry),
        ets:update_counter(State#state.consumer_table, ConsumerPid, {2, 1}, {ConsumerPid, 0})
    end, Entries),
    
    %% 重建过期堆（批量优化）
    NewHeap = rebuild_expire_heap(State#state.table),
    
    {reply, ok, State#state{expire_heap = NewHeap}}.
```

### 2. 消息确认 (ACK)

```erlang
%% 确认消息处理完成
handle_call({ack, MsgId}, _From, State) ->
    case ets:lookup(State#state.table, MsgId) of
        [] ->
            {reply, {error, not_found}, State};
        [Entry] ->
            %% 从 ETS 删除
            ets:delete(State#state.table, MsgId),
            
            %% 更新消费者计数
            ConsumerPid = Entry#inflight_entry.consumer_pid,
            ets:update_counter(State#state.consumer_table, ConsumerPid, {2, -1}),
            
            %% 从过期堆删除（lazy delete，标记即可）
            {reply, ok, State}
    end.

%% 批量 ACK（性能优化）
handle_call({ack_batch, MsgIds}, _From, State) ->
    Count = lists:foldl(fun(MsgId, Acc) ->
        case ets:lookup(State#state.table, MsgId) of
            [] -> Acc;
            [Entry] ->
                ets:delete(State#state.table, MsgId),
                ConsumerPid = Entry#inflight_entry.consumer_pid,
                ets:update_counter(State#state.consumer_table, ConsumerPid, {2, -1}),
                Acc + 1
        end
    end, 0, MsgIds),
    
    {reply, {ok, Count}, State}.
```

### 3. 超时检测（使用最小堆优化）

```erlang
%% 启动超时检查定时器
init([Topic, Channel]) ->
    Table = ets:new(inflight_table, [
        set, public, {keypos, #inflight_entry.msg_id}
    ]),
    ConsumerTable = ets:new(consumer_inflight, [
        set, public
    ]),
    
    %% 启动定时器
    TimerRef = erlang:send_after(?CHECK_INTERVAL, self(), check_expired),
    
    {ok, #state{
        table = Table,
        consumer_table = ConsumerTable,
        expire_heap = gb_trees:empty(),
        timer_ref = TimerRef,
        check_interval = ?CHECK_INTERVAL
    }}.

%% 检查过期消息
handle_info(check_expired, State) ->
    Now = erlang:system_time(millisecond),
    
    %% 从堆顶获取过期消息
    {ExpiredEntries, RemainingHeap} = collect_expired(
        State#state.expire_heap, 
        State#state.table, 
        Now, 
        []
    ),
    
    %% 处理过期消息
    lists:foreach(fun(Entry) ->
        handle_expired(Entry, State)
    end, ExpiredEntries),
    
    %% 计算下次检查时间
    NextCheckTime = case gb_trees:is_empty(RemainingHeap) of
        true -> Now + State#state.check_interval;
        false ->
            {{MinExpireTime, _}, _} = gb_trees:smallest(RemainingHeap),
            min(MinExpireTime, Now + State#state.check_interval)
    end,
    
    NextInterval = max(0, NextCheckTime - Now),
    NewTimer = erlang:send_after(NextInterval, self(), check_expired),
    
    {noreply, State#state{
        expire_heap = RemainingHeap,
        timer_ref = NewTimer
    }}.

%% 收集过期消息
collect_expired(Heap, Table, Now, Acc) ->
    case gb_trees:is_empty(Heap) of
        true -> {Acc, Heap};
        false ->
            {{Key = {ExpireTime, MsgId}, _}, NewHeap} = gb_trees:take_smallest(Heap),
            case ExpireTime =< Now of
                false -> 
                    {Acc, Heap};  %% 最早的都没过期
                true ->
                    %% 检查消息是否还存在（可能已被 ACK）
                    case ets:lookup(Table, MsgId) of
                        [] -> 
                            %% 已被 ACK，跳过
                            collect_expired(NewHeap, Table, Now, Acc);
                        [Entry] ->
                            collect_expired(NewHeap, Table, Now, [Entry | Acc])
                    end
            end
    end.

%% 处理单条过期消息
handle_expired(Entry, State) ->
    MsgId = Entry#inflight_entry.msg_id,
    ConsumerPid = Entry#inflight_entry.consumer_pid,
    
    %% 从 ETS 删除
    ets:delete(State#state.table, MsgId),
    
    %% 更新消费者计数
    ets:update_counter(State#state.consumer_table, ConsumerPid, {2, -1}),
    
    %% 增加重试次数
    Msg = Entry#inflight_entry.msg,
    NewMsg = Msg#nsq_message{attempts = Msg#nsq_message.attempts + 1},
    
    %% 通知 Channel 重新入队
    erwind_channel:requeue_delayed(
        self(), 
        NewMsg, 
        Entry#inflight_entry.retry_count + 1
    ),
    
    %% 更新统计
    erwind_stats:incr(channel, {inflight_timeout, 1}).
```

### 4. Touch 延长超时

```erlang
%% 消费者延长消息处理时间
handle_call({touch, MsgId, ExtendMs}, _From, State) ->
    case ets:lookup(State#state.table, MsgId) of
        [] ->
            {reply, {error, not_found}, State};
        [Entry] ->
            NewExpireTime = erlang:system_time(millisecond) + ExtendMs,
            
            %% 更新条目
            NewEntry = Entry#inflight_entry{
                expire_time = NewExpireTime,
                touched = true
            },
            ets:insert(State#state.table, NewEntry),
            
            %% 更新过期堆（插入新时间，旧的在检查时会跳过）
            NewHeap = gb_trees:insert(
                {NewExpireTime, MsgId}, 
                MsgId, 
                State#state.expire_heap
            ),
            
            {reply, ok, State#state{expire_heap = NewHeap}}
    end.
```

### 5. 重新入队 (Requeue)

```erlang
%% 主动重新入队（REQ 命令）
handle_call({requeue, MsgId, DelayMs}, _From, State) ->
    case ets:lookup(State#state.table, MsgId) of
        [] ->
            {reply, {error, not_found}, State};
        [Entry] ->
            %% 从 ETS 删除
            ets:delete(State#state.table, MsgId),
            
            %% 更新消费者计数
            ConsumerPid = Entry#inflight_entry.consumer_pid,
            ets:update_counter(State#state.consumer_table, ConsumerPid, {2, -1}),
            
            %% 增加重试次数
            Msg = Entry#inflight_entry.msg,
            NewMsg = Msg#nsq_message{
                attempts = Msg#nsq_message.attempts + 1
            },
            
            {reply, {ok, NewMsg}, State}
    end.
```

## 与 Channel 的协作

```
Channel                                InflightTracker
  │                                         │
  │──deliver_to_consumer(Msg, Consumer)────>│
  │                                         │──track(MsgId, Msg, Consumer, Timeout)
  │                                         │
  │<─────────────────────────────────────ok │
  │                                         │
  │──[time passes...]                       │
  │                                         │──[check_expired timer]
  │                                         │
  │<─────────────────requeue_delayed(Msg)───│
  │                                         │
  │──[Consumer sends FIN]                   │
  │                                         │
  │──ack(MsgId)────────────────────────────>│
  │                                         │──ets:delete(MsgId)
  │<─────────────────────────────────────ok │
```

## 依赖关系

### 依赖的模块
- `erwind_stats` - 上报超时统计

### 被依赖的模块
- `erwind_channel` - 调用 track/ack/requeue

## 配置参数

```erlang
{erwind_inflight_tracker, [
    {check_interval, 5000},           %% 超时检查间隔（毫秒）
    {max_retry_count, 5},             %% 最大重试次数
    {use_heap_optimization, true},    %% 使用最小堆优化
    {lazy_delete, true}               %% 惰性删除已 ACK 消息
]}.
```

## 性能优化

| 操作 | 时间复杂度 | 实现方式 |
|------|-----------|---------|
| track | O(log N) | ETS insert + gb_trees insert |
| ack | O(1) | ETS delete |
| check_expired | O(K log N) | K 是过期消息数 |
| get_inflight_count | O(1) | ets:info(size) |

## 监控指标

```erlang
%% 通过 erwind_stats 上报
#{
    inflight_total => integer(),           %% 总在途消息数
    inflight_by_consumer => map(),         %% 各消费者在途数
    inflight_timeouts_rate => float(),     %% 超时率
    avg_inflight_duration => float()       %% 平均在途时长
}
```
