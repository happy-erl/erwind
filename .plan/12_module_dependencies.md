# Erwind 模块依赖关系详解

## 一、分层依赖图

```
┌────────────────────────────────────────────────────────────────────────────┐
│ Layer 7: Application Layer                                                  │
├────────────────────────────────────────────────────────────────────────────┤
│ erwind_app ──────┬──────> erwind_sup                                        │
│                  │                                                          │
│                  └──────> erwind_config                                     │
└────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    v
┌────────────────────────────────────────────────────────────────────────────┐
│ Layer 6: Supervisor Layer                                                   │
├────────────────────────────────────────────────────────────────────────────┤
│ erwind_sup                                                                     │
│   ├── erwind_tcp_sup ─────┬──> erwind_tcp_listener                          │
│   │                       ├──> erwind_acceptor_pool_sup                     │
│   │                       └──> erwind_connection_sup                        │
│   ├── erwind_http_sup ────┬──> erwind_http_api                              │
│   │                       └──> cowboy (external)                            │
│   ├── erwind_core_sup ────┬──> erwind_topic_sup                             │
│   │                       └──> erwind_channel_sup                           │
│   ├── erwind_storage_sup ─┬──> erwind_diskqueue_sup                         │
│   │                       └──> erwind_backend_queue                         │
│   └── erwind_service_sup ─┬──> erwind_stats                                 │
│                           ├──> erwind_lookupd                               │
│                           └──> erwind_cluster (optional)                    │
└────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    v
┌────────────────────────────────────────────────────────────────────────────┐
│ Layer 5: Transport Layer                                                    │
├────────────────────────────────────────────────────────────────────────────┤
│ erwind_tcp_listener ────> erwind_acceptor                                   │
│     │                                                                       │
│     └───────────────────────> gen_tcp (kernel)                              │
│                                                                             │
│ erwind_acceptor ──────────> erwind_connection_sup                           │
│     │                                                                       │
│     └───────────────────────> erwind_tcp_listener (get socket)              │
│                                                                             │
│ erwind_connection ────────┬──> erwind_protocol (encode/decode)              │
│     │                     ├──> erwind_channel (subscribe)                   │
│     │                     └──> erwind_topic (publish)                       │
│                                                                             │
│ erwind_http_api ──────────┬──> erwind_topic_registry                        │
│                           ├──> erwind_topic (management)                    │
│                           └──> erwind_stats (metrics)                       │
└────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    v
┌────────────────────────────────────────────────────────────────────────────┐
│ Layer 4: Protocol Layer                                                     │
├────────────────────────────────────────────────────────────────────────────┤
│ erwind_protocol ──────────┬──> erwind_protocol_codec                        │
│     │                     ├──> erwind_command_parser                        │
│     │                     └──> erwind_auth (optional)                       │
│                                                                             │
│ erwind_protocol_codec ────┬──> jsx (external)                               │
│                           └──> crypto (for msg_id)                          │
│                                                                             │
│ erwind_command_parser                                                                     │
└────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    v
┌────────────────────────────────────────────────────────────────────────────┐
│ Layer 3: Core Logic Layer                                                   │
├────────────────────────────────────────────────────────────────────────────┤
│ erwind_topic ─────────────┬──> erwind_topic_registry (register)             │
│     │                     ├──> erwind_channel_sup (create channel)          │
│     │                     ├──> erwind_backend_queue (persist)               │
│     │                     └──> erwind_message_router (optional)             │
│                                                                             │
│ erwind_channel ───────────┬──> erwind_consumer_manager                      │
│     │                     ├──> erwind_memory_queue                          │
│     │                     ├──> erwind_inflight_tracker                      │
│     │                     ├──> erwind_delayed_queue                         │
│     │                     └──> erwind_backend_queue (overflow)              │
│                                                                             │
│ erwind_consumer_manager ──┬──> erwind_stats (metrics)                       │
│     │                     └──> erwind_load_balancer (optional)              │
│                                                                             │
│ erwind_message_router ────┬──> erwind_delayed_queue (DLQ)                  │
│                           └──> erwind_topic (retry)                         │
└────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    v
┌────────────────────────────────────────────────────────────────────────────┐
│ Layer 2: Storage Layer                                                      │
├────────────────────────────────────────────────────────────────────────────┤
│ erwind_backend_queue ─────┬──> erwind_memory_queue                          │
│     │                     └──> erwind_diskqueue (overflow)                  │
│                                                                             │
│ erwind_memory_queue ──────> queue (stdlib)                                  │
│                                                                             │
│ erwind_diskqueue ─────────┬──> file (kernel)                                │
│     │                     ├──> erwind_gc (cleanup)                          │
│     │                     └──> jsx (metadata)                               │
│                                                                             │
│ erwind_inflight_tracker ──> ets (stdlib)                                    │
│                                                                             │
│ erwind_delayed_queue ─────┬──> ets (pending queue)                          │
│     │                     └──> erlang:send_after (timer)                    │
│                                                                             │
│ erwind_gc ────────────────> erwind_diskqueue (cleanup)                      │
└────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    v
┌────────────────────────────────────────────────────────────────────────────┐
│ Layer 1: Service Layer                                                      │
├────────────────────────────────────────────────────────────────────────────┤
│ erwind_stats ─────────────> ets (multiple tables)                           │
│                                                                             │
│ erwind_lookupd ───────────┬──> hackney (external)                           │
│     │                     └──> jsx (external)                               │
│                                                                             │
│ erwind_cluster ───────────┬──> net_kernel (distributed Erlang)              │
│                           └──> erwind_lookupd (discovery)                   │
│                                                                             │
│ erwind_topic_registry ────> ets (named_table)                               │
└────────────────────────────────────────────────────────────────────────────┘
```

---

## 二、运行时依赖流程

### 2.1 消息发布流程

```
erwind_connection (receive PUB)
    │
    v
erwind_command_parser (parse command)
    │
    v
erwind_topic:publish(Topic, Msg)
    │
    ├──────> erwind_topic_registry (lookup Topic pid)
    │
    v
erwind_topic:handle_cast({publish, Msg}, State)
    │
    ├──────> erwind_backend_queue:put(Backend, Msg) [async persist]
    │
    ├──────> erwind_stats:incr(topic, MsgCount)
    │
    v
lists:foreach(fun(Channel) ->
    erwind_channel:put_message(Channel, Msg)
end, Channels)
    │
    v
erwind_channel:handle_cast({put_message, Msg}, State)
    │
    ├──────> try_deliver(Msg, State)
    │           │
    │           v
    │       erwind_consumer_manager:select_consumer(Consumers)
    │           │
    │           v
    │       erwind_connection:send(ConsumerPid, MsgFrame)
    │           │
    │           v
    │       erwind_inflight_tracker:track(MsgId, ConsumerPid)
    │
    └──────> erwind_memory_queue:in(Msg) [if no consumer ready]
```

### 2.2 消息消费流程

```
erwind_connection (receive SUB)
    │
    v
erwind_topic:get_channel(Topic, ChannelName)
    │
    v
erwind_channel:subscribe(ChannelPid, ConsumerPid)
    │
    v
erwind_consumer_manager:register(ChannelPid, ConsumerPid)
    │
    v
erwind_channel:try_drain_queue(State)
    │
    ├──────> erwind_memory_queue:out(Queue)
    │           │
    │           v
    │       deliver_to_consumer(Msg, Consumer)
    │
    v
erwind_connection (receive RDY)
    │
    v
erwind_consumer_manager:update_rdy(ConsumerPid, Count)
    │
    v
erwind_channel:try_drain_queue(State) [trigger delivery]

[Consumer processing...]

erwind_connection (receive FIN)
    │
    v
erwind_inflight_tracker:ack(MsgId)
    │
    v
erwind_consumer_manager:decr_inflight(ConsumerPid)
```

### 2.3 延迟消息流程

```
erwind_connection (receive DPUB)
    │
    v
erwind_delayed_queue:schedule(Msg, DeferMs)
    │
    v
ets:insert(delayed_msgs, #delayed_msg{
    msg = Msg,
    trigger_time = Now + DeferMs
})
    │
    v
erlang:send_after(DeferMs, self(), {trigger_delayed, MsgId})
    │
[time passes...]
    │
    v
erwind_delayed_queue:handle_info({trigger_delayed, MsgId}, State)
    │
    v
erwind_topic:publish(Topic, Msg) [re-inject to topic]
```

---

## 三、监督树依赖

```
erwind_sup (one_for_one)
│
├── erwind_topic_registry (permanent worker)
│   └── ets:new(topic_registry, [named_table, public])
│
├── erwind_tcp_sup (permanent supervisor, rest_for_one)
│   │
│   ├── erwind_tcp_listener (permanent worker)
│   │   └── gen_tcp:listen(Port, Opts)
│   │
│   ├── erwind_acceptor_pool_sup (permanent supervisor, one_for_one)
│   │   ├── erwind_acceptor_1 (permanent worker)
│   │   ├── erwind_acceptor_2 (permanent worker)
│   │   └── ... (N acceptors)
│   │
│   └── erwind_connection_sup (permanent supervisor, simple_one_for_one)
│       └── erwind_connection (temporary worker, dynamic)
│
├── erwind_core_sup (permanent supervisor, one_for_one)
│   │
│   ├── erwind_topic_sup (permanent supervisor, simple_one_for_one)
│   │   └── erwind_topic (temporary worker, dynamic)
│   │       └── erwind_channel_sup (permanent supervisor, simple_one_for_one)
│   │           └── erwind_channel (temporary worker, dynamic)
│   │               ├── erwind_consumer_manager (permanent worker)
│   │               ├── erwind_memory_queue (permanent worker)
│   │               ├── erwind_inflight_tracker (permanent worker)
│   │               └── erwind_delayed_queue (permanent worker)
│   │
│   └── erwind_message_router (permanent worker, optional)
│
├── erwind_storage_sup (permanent supervisor, one_for_one)
│   │
│   ├── erwind_diskqueue_sup (permanent supervisor, simple_one_for_one)
│   │   └── erwind_diskqueue (temporary worker, dynamic)
│   │
│   ├── erwind_backend_queue (permanent worker)
│   │   ├── erwind_memory_queue
│   │   └── erwind_diskqueue (overflow)
│   │
│   └── erwind_gc (permanent worker)
│
├── erwind_http_sup (permanent supervisor, one_for_one)
│   └── erwind_http_api (permanent worker)
│       └── cowboy:start_clear(...)
│
└── erwind_service_sup (permanent supervisor, one_for_one)
    ├── erwind_stats (permanent worker)
    │   ├── ets:topic_stats
    │   ├── ets:channel_stats
    │   └── ets:consumer_stats
    │
    ├── erwind_lookupd (permanent worker)
    │   └── hackney_pool:start_pool(...)
    │
    └── erwind_cluster (permanent worker, optional)
```

---

## 四、循环依赖检查

### 4.1 潜在循环依赖

#### 问题 1: Connection <-> Channel
```
erwind_connection ───> erwind_channel:subscribe/2
      ↑                      │
      └──────────────────────┘
   (channel sends messages back to connection)
```

**解决**: 使用消息传递而非直接调用
```erlang
%% Connection 发送订阅请求
ChannelPid ! {subscribe, self()}.

%% Channel 异步发送消息到 Connection
ConsumerPid ! {deliver_message, Msg}.
```

#### 问题 2: Topic <-> Channel
```
erwind_topic ───> erwind_channel_sup:start_child/2
      ↑                      │
      └──────────────────────┘
   (channel needs topic name for lookupd registration)
```

**解决**: 通过参数传递，避免运行时依赖
```erlang
%% Topic 启动 Channel 时传递必要信息
erwind_channel:start_link(TopicName, ChannelName).
```

#### 问题 3: Backend Queue <-> Diskqueue
```
erwind_backend_queue ───> erwind_diskqueue:put/2
      ↑                           │
      └───────────────────────────┘
   (diskqueue might call backend for stats)
```

**解决**: 使用事件订阅模式
```erlang
%% Diskqueue 发布事件
erwind_event_bus:publish({diskqueue, write_complete}, Stats).

%% Backend Queue 订阅事件
erwind_event_bus:subscribe({diskqueue, write_complete}).
```

### 4.2 依赖方向规范

```
允许的方向:
    上层 ───> 下层
    Core ───> Storage
    Core ───> Service
    Transport ───> Core

禁止的方向:
    Storage ─X──> Core
    Service ─X──> Core (except via events)
    Core ─X──> Transport
```

---

## 五、启动顺序

```
Phase 1: 基础服务 (无依赖)
    1. erwind_topic_registry (ETS)
    2. erwind_config (配置加载)
    3. erwind_stats (统计ETS)

Phase 2: 存储层
    4. erwind_diskqueue_sup
    5. erwind_gc
    6. erwind_backend_queue

Phase 3: 核心逻辑
    7. erwind_topic_sup
    8. erwind_delayed_queue
    9. erwind_message_router (optional)

Phase 4: 传输层
    10. erwind_tcp_listener
    11. erwind_acceptor_pool_sup
    12. erwind_connection_sup
    13. erwind_http_api

Phase 5: 服务层
    14. erwind_lookupd
    15. erwind_cluster (optional)
```

---

## 六、外部依赖

### 6.1 必需依赖

| 库 | 用途 | 版本 |
|----|------|------|
| kernel | Erlang 核心 | 内置 |
| stdlib | 标准库 | 内置 |
| sasl | 监督报告 | 内置 |
| crypto | 消息ID生成 | 内置 |
| jsx | JSON编解码 | 3.1.0 |
| cowboy | HTTP服务器 | 2.9.0 |

### 6.2 可选依赖

| 库 | 用途 | 版本 |
|----|------|------|
| hackney | HTTP客户端 (lookupd) | 1.18.1 |
| lager | 日志 | 3.9.2 |
| prometheus | 指标导出 | 4.8.1 |
| statsderl | StatsD客户端 | 0.4.5 |
| ssl | TLS支持 | 内置 |

### 6.3 测试依赖

| 库 | 用途 | 版本 |
|----|------|------|
| eunit | 单元测试 | 内置 |
| common_test | 集成测试 | 内置 |
| proper | 属性测试 | 1.4.0 |
| meck | Mock框架 | 0.9.2 |
| gun | HTTP客户端测试 | 2.0.0 |

---

## 七、模块接口契约

### 7.1 核心接口

```erlang
%% erwind_topic
-type topic_ref() :: pid() | binary().
-spec publish(topic_ref(), binary()) -> ok | {error, term()}.
-spec get_channel(topic_ref(), binary()) -> {ok, pid()}.

%% erwind_channel
-type channel_ref() :: pid().
-spec subscribe(channel_ref(), pid()) -> ok.
-spec put_message(channel_ref(), #nsq_message{}) -> ok.

%% erwind_consumer_manager
-spec register(pid(), map()) -> {ok, consumer_id()}.
-spec select_consumer([pid()], strategy()) -> {ok, pid()} | empty.

%% erwind_inflight_tracker
-spec track(pid(), binary(), #nsq_message{}, timeout()) -> ok.
-spec ack(pid(), binary()) -> ok | {error, not_found}.
```

### 7.2 存储接口

```erlang
%% erwind_backend_queue
-spec put(pid(), #nsq_message{}) -> ok.
-spec get(pid()) -> {ok, #nsq_message{}} | empty.

%% erwind_diskqueue
-spec write(file:io_device(), binary()) -> ok.
-spec read(file:io_device()) -> {ok, binary()} | eof.
```

### 7.3 服务接口

```erlang
%% erwind_stats
-spec incr(atom(), term()) -> integer().
-spec gauge(atom(), term(), number()) -> ok.

%% erwind_lookupd
-spec register_topic(binary()) -> ok.
-spec lookup_topic(binary()) -> {ok, [node_info()]}.
```
