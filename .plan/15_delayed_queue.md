# 延迟队列模块 (erwind_delayed_queue)

## 功能概述

延迟队列模块负责管理需要延迟投递的消息，使用分层时间轮（Hierarchical Time Wheel）实现高效的延迟调度。这是从原 Topic/Channel 中拆分出来的独立模块。

## 为什么需要时间轮

### 简单方案的局限性

```erlang
%% 方案1: 每个消息一个定时器
schedule(Msg, DelayMs) ->
    erlang:send_after(DelayMs, self(), {deliver, Msg}).
%% 问题：1万条消息 = 1万个定时器，内存和CPU开销大

%% 方案2: 排序列表 + 定时扫描
schedule(Msg, DelayMs) ->
    TriggerTime = now() + DelayMs,
    ets:insert(delayed_msgs, {TriggerTime, Msg}).
%% 问题：扫描是O(N)，消息量大时性能差
```

### 时间轮方案优势

- **O(1) 插入和到期触发**
- **分层设计**：支持从毫秒到天的任意延迟
- **内存友好**：固定数量的槽位

## 分层时间轮设计

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│  Wheel 0    │───>│  Wheel 1    │───>│  Wheel 2    │───>│  Wheel 3    │
│  (1ms tick) │    │  (1s tick)  │    │  (1min tick)│    │  (1hour tick)│
│  100 slots  │    │  60 slots   │    │  60 slots   │    │  24 slots   │
│  = 100ms    │    │  = 60s      │    │  = 60min    │    │  = 24hour   │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘

消息到期流程：
1. 新消息放入 Wheel 0 (如 50ms 后到期)
2. 每 1ms tick，Wheel 0 前进一格
3. Wheel 0 转一圈后，从 Wheel 1 取消息降级
4. 层级越高，时间精度越低，但支持的延迟越长
```

## 数据结构

```erlang
-module(erwind_delayed_queue).
-behaviour(gen_server).

%% 延迟消息记录
-record(delayed_msg, {
    id :: binary(),                 %% 消息ID
    msg :: #nsq_message{},
    target_topic :: binary(),
    target_channel :: binary() | undefined,
    trigger_time :: integer(),      %% 到期时间戳
    retry_count = 0 :: integer()    %% 延迟投递重试次数
}).

%% 时间轮槽位
-record(wheel_slot, {
    index :: integer(),             %% 槽位索引
    msgs = [] :: [#delayed_msg{}]   %% 该槽位的消息列表
}).

%% 时间轮状态
-record(wheel, {
    level :: integer(),             %% 0=ms, 1=s, 2=min, 3=hour
    slots :: array:array(),         %% 槽位数组
    current_index = 0 :: integer(), %% 当前指针
    slot_count :: integer(),        %% 槽位数
    tick_duration :: integer()      %% 每个槽位的时间跨度(ms)
}).

%% 整体状态
-record(state, {
    wheels :: [#wheel{}],           %% 4层时间轮
    msg_index :: ets:tid(),         %% ETS: msg_id -> {level, slot_index}
    timer_ref :: reference(),       %% 当前tick定时器
    tick_interval = 1 :: integer()  %% 基础tick间隔(ms)
}).
```

## API 接口

```erlang
%% 启动
-spec start_link(Topic :: binary(), Channel :: binary() | undefined) -> 
    {ok, pid()}.

%% 调度消息
-spec schedule(pid(), #nsq_message{}, DelayMs :: integer()) -> 
    {ok, MsgId :: binary()}.
-spec schedule_to_topic(pid(), #nsq_message{}, DelayMs :: integer(), 
                        Topic :: binary()) -> {ok, MsgId :: binary()}.

%% 取消调度
-spec cancel(pid(), MsgId :: binary()) -> ok | {error, not_found}.

%% 查询
-spec get_pending_count(pid()) -> integer().
-spec get_pending_by_topic(pid(), Topic :: binary()) -> integer().

%% 持久化
-spec save_to_disk(pid()) -> ok.
-spec load_from_disk(pid()) -> ok.
```

## 核心逻辑

### 1. 初始化时间轮

```erlang
init([Topic, Channel]) ->
    %% 创建4层时间轮
    Wheels = [
        %% Level 0: 1ms tick, 100 slots = 100ms
        #wheel{
            level = 0,
            slots = array:new(100, {default, #wheel_slot{}}),
            current_index = 0,
            slot_count = 100,
            tick_duration = 1
        },
        %% Level 1: 100ms tick (当level 0转一圈), 600 slots = 60s
        #wheel{
            level = 1,
            slots = array:new(600, {default, #wheel_slot{}}),
            current_index = 0,
            slot_count = 600,
            tick_duration = 100
        },
        %% Level 2: 1s tick, 3600 slots = 1hour
        #wheel{
            level = 2,
            slots = array:new(3600, {default, #wheel_slot{}}),
            current_index = 0,
            slot_count = 3600,
            tick_duration = 1000
        },
        %% Level 3: 1min tick, 1440 slots = 24hour
        #wheel{
            level = 3,
            slots = array:new(1440, {default, #wheel_slot{}}),
            current_index = 0,
            slot_count = 1440,
            tick_duration = 60000
        }
    ],
    
    %% 创建消息索引
    MsgIndex = ets:new(delayed_msg_index, [set, public]),
    
    %% 启动tick定时器
    TimerRef = erlang:send_after(1, self(), tick),
    
    {ok, #state{
        wheels = Wheels,
        msg_index = MsgIndex,
        timer_ref = TimerRef
    }}.
```

### 2. 消息调度

```erlang
%% 计算消息应该放入哪一层
handle_call({schedule, Msg, DelayMs}, _From, State) ->
    Now = erlang:system_time(millisecond),
    TriggerTime = Now + DelayMs,
    
    MsgId = erwind_protocol:generate_msg_id(),
    DelayedMsg = #delayed_msg{
        id = MsgId,
        msg = Msg,
        target_topic = State#state.topic,
        target_channel = State#state.channel,
        trigger_time = TriggerTime
    },
    
    %% 根据延迟时间选择层级
    {Level, SlotIndex} = calculate_slot(State#state.wheels, DelayMs),
    
    %% 获取对应时间轮
    Wheel = lists:nth(Level + 1, State#state.wheels),
    
    %% 插入消息到槽位
    Slot = array:get(SlotIndex, Wheel#wheel.slots),
    NewSlot = Slot#wheel_slot{
        msgs = [DelayedMsg | Slot#wheel_slot.msgs]
    },
    NewSlots = array:set(SlotIndex, NewSlot, Wheel#wheel.slots),
    NewWheel = Wheel#wheel{slots = NewSlots},
    NewWheels = update_wheel_list(State#state.wheels, Level, NewWheel),
    
    %% 记录消息位置
    ets:insert(State#state.msg_index, {MsgId, Level, SlotIndex}),
    
    {reply, {ok, MsgId}, State#state{wheels = NewWheels}}.

%% 计算消息应该放入哪个槽位
calculate_slot(Wheels, DelayMs) when DelayMs =< 100 ->
    %% Level 0: 0-100ms
    {0, DelayMs};
calculate_slot(Wheels, DelayMs) when DelayMs =< 60000 ->
    %% Level 1: 100ms-60s
    Wheel = lists:nth(2, Wheels),
    Slot = (DelayMs div 100) rem Wheel#wheel.slot_count,
    {1, Slot};
calculate_slot(Wheels, DelayMs) when DelayMs =< 3600000 ->
    %% Level 2: 1s-1hour
    Wheel = lists:nth(3, Wheels),
    Slot = (DelayMs div 1000) rem Wheel#wheel.slot_count,
    {2, Slot};
calculate_slot(Wheels, DelayMs) ->
    %% Level 3: >1hour, max 24hour
    Wheel = lists:nth(4, Wheels),
    Slot = min((DelayMs div 60000) rem Wheel#wheel.slot_count, 
               Wheel#wheel.slot_count - 1),
    {3, Slot}.
```

### 3. Tick 处理（时间轮推进）

```erlang
%% 定时器触发
handle_info(tick, State) ->
    %% 处理最底层时间轮的当前槽位
    [Wheel0 | HigherWheels] = State#state.wheels,
    
    %% 获取当前槽位的消息
    CurrentSlot = array:get(Wheel0#wheel.current_index, Wheel0#wheel.slots),
    ExpiredMsgs = CurrentSlot#wheel_slot.msgs,
    
    %% 清空槽位
    NewSlot0 = CurrentSlot#wheel_slot{msgs = []},
    NewSlots0 = array:set(Wheel0#wheel.current_index, NewSlot0, 
                          Wheel0#wheel.slots),
    
    %% 推进指针
    NextIndex = (Wheel0#wheel.current_index + 1) rem Wheel0#wheel.slot_count,
    NewWheel0 = Wheel0#wheel{
        slots = NewSlots0,
        current_index = NextIndex
    },
    
    %% 检查是否需要从上层降级消息
    {NewWheels, DowngradedMsgs} = case NextIndex of
        0 -> 
            %% Wheel 0 转了一圈，从 Wheel 1 取消息
            downgrade_from_upper_level(HigherWheels, 1);
        _ -> 
            {HigherWheels, []}
    end,
    
    %% 合并消息
    AllExpired = ExpiredMsgs ++ DowngradedMsgs,
    
    %% 触发投递
    lists:foreach(fun(Msg) ->
        ets:delete(State#state.msg_index, Msg#delayed_msg.id),
        deliver_delayed_msg(Msg)
    end, AllExpired),
    
    %% 重启定时器
    NewTimer = erlang:send_after(State#state.tick_interval, self(), tick),
    
    {noreply, State#state{
        wheels = [NewWheel0 | NewWheels],
        timer_ref = NewTimer
    }}.

%% 从上层降级消息
downgrade_from_upper_level(Wheels, Level) ->
    case Level > length(Wheels) of
        true -> {Wheels, []};
        false ->
            Wheel = lists:nth(Level, Wheels),
            Slot = array:get(Wheel#wheel.current_index, Wheel#wheel.slots),
            Msgs = Slot#wheel_slot.msgs,
            
            %% 清空上层槽位
            NewSlot = Slot#wheel_slot{msgs = []},
            NewSlots = array:set(Wheel#wheel.current_index, NewSlot, 
                                Wheel#wheel.slots),
            NextIndex = (Wheel#wheel.current_index + 1) rem Wheel#wheel.slot_count,
            NewWheel = Wheel#wheel{
                slots = NewSlots,
                current_index = NextIndex
            },
            
            %% 将消息放入下层（重新计算槽位）
            {NewWheels, Downgraded} = lists:foldl(fun(Msg, {Ws, Acc}) ->
                Now = erlang:system_time(millisecond),
                RemainingDelay = max(0, Msg#delayed_msg.trigger_time - Now),
                {L, Idx} = calculate_slot([NewWheel | Ws], RemainingDelay),
                
                TargetWheel = lists:nth(L + 1, [NewWheel | Ws]),
                TargetSlot = array:get(Idx, TargetWheel#wheel.slots),
                NewTargetSlot = TargetSlot#wheel_slot{
                    msgs = [Msg | TargetSlot#wheel_slot.msgs]
                },
                NewTargetSlots = array:set(Idx, NewTargetSlot, 
                                          TargetWheel#wheel.slots),
                FinalWheel = TargetWheel#wheel{slots = NewTargetSlots},
                FinalWheels = update_wheel_list([NewWheel | Ws], L, FinalWheel),
                
                {FinalWheels, Acc}
            end, {lists:sublist([NewWheel | Wheels], 2, length(Wheels)), []}, Msgs),
            
            {NewWheels, Downgraded}
    end.
```

### 4. 消息投递

```erlang
%% 触发延迟消息投递
deliver_delayed_msg(#delayed_msg{target_topic = Topic, 
                                  target_channel = undefined,
                                  msg = Msg}) ->
    %% 投递到 Topic
    case erwind_topic_registry:lookup(Topic) of
        {ok, TopicPid} ->
            erwind_topic:publish(TopicPid, Msg#nsq_message.body);
        not_found ->
            error_logger:warning_msg("Delayed topic ~p not found", [Topic])
    end;

deliver_delayed_msg(#delayed_msg{target_topic = Topic,
                                  target_channel = Channel,
                                  msg = Msg}) ->
    %% 投递到 Channel
    case erwind_topic_registry:lookup(Topic) of
        {ok, TopicPid} ->
            {ok, ChannelPid} = erwind_topic:get_channel(TopicPid, Channel),
            erwind_channel:put_message(ChannelPid, Msg);
        not_found ->
            error_logger:warning_msg("Delayed channel ~p/~p not found", 
                                    [Topic, Channel])
    end.
```

### 5. 取消调度

```erlang
handle_call({cancel, MsgId}, _From, State) ->
    case ets:lookup(State#state.msg_index, MsgId) of
        [] ->
            {reply, {error, not_found}, State};
        [{MsgId, Level, SlotIndex}] ->
            %% 从时间轮移除
            Wheel = lists:nth(Level + 1, State#state.wheels),
            Slot = array:get(SlotIndex, Wheel#wheel.slots),
            
            %% 过滤掉目标消息
            NewMsgs = lists:filter(
                fun(M) -> M#delayed_msg.id =/= MsgId end, 
                Slot#wheel_slot.msgs
            ),
            
            NewSlot = Slot#wheel_slot{msgs = NewMsgs},
            NewSlots = array:set(SlotIndex, NewSlot, Wheel#wheel.slots),
            NewWheel = Wheel#wheel{slots = NewSlots},
            NewWheels = update_wheel_list(State#state.wheels, Level, NewWheel),
            
            %% 从索引删除
            ets:delete(State#state.msg_index, MsgId),
            
            {reply, ok, State#state{wheels = NewWheels}}
    end.
```

## 持久化

```erlang
%% 保存延迟消息到磁盘（用于重启恢复）
handle_call(save_to_disk, _From, State) ->
    %% 收集所有消息
    AllMsgs = lists:foldl(fun(Wheel, Acc) ->
        lists:foldl(fun(SlotIdx, Acc2) ->
            Slot = array:get(SlotIdx, Wheel#wheel.slots),
            Slot#wheel_slot.msgs ++ Acc2
        end, Acc, lists:seq(0, Wheel#wheel.slot_count - 1))
    end, [], State#state.wheels),
    
    %% 编码保存
    Data = term_to_binary(AllMsgs),
    File = filename:join(get_data_dir(), "delayed_queue.dat"),
    file:write_file(File, Data),
    
    {reply, ok, State}.

%% 从磁盘加载
handle_call(load_from_disk, _From, State) ->
    File = filename:join(get_data_dir(), "delayed_queue.dat"),
    case file:read_file(File) of
        {ok, Data} ->
            Msgs = binary_to_term(Data),
            %% 重新调度所有消息
            lists:foreach(fun(Msg) ->
                Now = erlang:system_time(millisecond),
                RemainingDelay = max(0, Msg#delayed_msg.trigger_time - Now),
                handle_call({schedule, Msg#delayed_msg.msg, RemainingDelay}, 
                           self(), State)
            end, Msgs),
            {reply, ok, State};
        {error, _} ->
            {reply, {error, no_data}, State}
    end.
```

## 与 Topic/Channel 的协作

```
Topic/Channel                        DelayedQueue
    │                                     │
    │──dpub(Msg, DeferMs)────────────────>│
    │                                     │──calculate_slot()
    │                                     │──insert to wheel
    │<──────────────────────────────{ok, Id}│
    │                                     │
    │                                     │──[timer tick...]
    │                                     │
    │<─────────────────deliver_delayed_msg()│
    │                                     │──erwind_topic:publish()
```

## 性能特性

| 操作 | 时间复杂度 | 说明 |
|------|-----------|------|
| schedule | O(1) | 直接计算槽位 |
| cancel | O(K) | K是该槽位消息数，通常很小 |
| tick | O(M) | M是到期消息数 |
| 内存 | O(N) | N是总延迟消息数 |

## 配置参数

```erlang
{erwind_delayed_queue, [
    {tick_interval, 1},              %% tick间隔(ms)
    {wheel_0_slots, 100},            %% ms级槽位数
    {wheel_1_slots, 600},            %% 100ms级槽位数
    {wheel_2_slots, 3600},           %% s级槽位数
    {wheel_3_slots, 1440},           %% min级槽位数
    {max_delay_ms, 86400000},        %% 最大延迟24小时
    {persist_interval, 60000}        %% 持久化间隔(ms)
]}.
```

## 监控指标

```erlang
#{
    delayed_pending_total => integer(),     %% 待处理延迟消息数
    delayed_by_level => [integer()],        %% 各层级消息数
    delayed_delivered_rate => float(),      %% 投递速率
    delayed_cancelled_rate => float()       %% 取消速率
}
```
