# 实施计划 (Implementation Plan)

## 模块依赖关系

```
依赖方向: A -> B 表示 A 依赖 B

Layer 1 (基础设施):
├── erwind_app
├── erwind_sup
├── erwind_config
└── erwind_topic_registry (ETS)

Layer 2 (网络层):
├── erwind_tcp_listener -> erwind_protocol
├── erwind_acceptor
├── erwind_connection -> erwind_protocol, erwind_channel
└── erwind_http_api -> cowboy

Layer 3 (协议层):
└── erwind_protocol -> jsx

Layer 4 (核心逻辑):
├── erwind_topic -> erwind_channel_sup, erwind_backend_queue, erwind_lookupd
├── erwind_topic_sup
├── erwind_channel -> erwind_backend_queue, erwind_consumer
├── erwind_channel_sup
└── erwind_consumer -> erwind_connection

Layer 5 (存储层):
├── erwind_backend_queue -> erwind_diskqueue_sup
├── erwind_diskqueue
└── erwind_diskqueue_sup

Layer 6 (服务层):
├── erwind_stats
├── erwind_lookupd -> hackney, jsx
└── erwind_diskqueue
```

## 实现顺序

### Phase 1: 基础框架 (Week 1)
```erlang
1. erwind.app.src          %% OTP 应用配置
2. erwind_app.erl          %% 应用启动
3. erwind_sup.erl          %% 根监督者
4. erwind_topic_registry.erl  %% ETS 注册表
5. erwind_config.erl       %% 配置管理
```

### Phase 2: 协议层 (Week 1-2)
```erlang
6. erwind_protocol.erl     %% NSQ 协议编解码
   - 帧编解码
   - 命令解析
   - 消息 ID 生成
```

### Phase 3: 网络层 (Week 2)
```erlang
7. erwind_tcp_sup.erl      %% TCP 监督树
8. erwind_tcp_listener.erl %% TCP 监听
9. erwind_acceptor.erl     %% Acceptor 进程
10. erwind_connection.erl  %% 连接处理 (gen_statem)
```

### Phase 4: 存储层 (Week 2-3)
```erlang
11. erwind_diskqueue.erl   %% 磁盘队列
12. erwind_diskqueue_sup.erl %% 磁盘队列监督者
13. erwind_backend_queue.erl %% Backend 队列
```

### Phase 5: 核心逻辑 (Week 3-4)
```erlang
14. erwind_topic_sup.erl   %% Topic 监督者
15. erwind_topic.erl       %% Topic 进程
16. erwind_channel_sup.erl %% Channel 监督者
17. erwind_channel.erl     %% Channel 进程
```

### Phase 6: 管理接口 (Week 4)
```erlang
18. erwind_http_sup.erl    %% HTTP 监督树
19. erwind_http_api.erl    %% HTTP API
20. erwind_stats.erl       %% 统计模块
21. erwind_lookupd.erl     %% nsqlookupd 客户端
```

### Phase 7: 集成测试 (Week 5)
```erlang
22. 集成测试
23. 性能测试
24. 容错测试
```

## 文件结构

```
/home/tang/erl/erwind/
├── src/
│   ├── erwind.app.src
│   ├── erwind_app.erl
│   ├── erwind_sup.erl
│   ├── erwind_config.erl
│   ├── erwind_topic_registry.erl
│   │
│   ├── erwind_protocol.erl
│   │   - 定义 record: nsq_message
│   │   - encode_response/1
│   │   - encode_error/1
│   │   - encode_message/1
│   │   - decode_frame/1
│   │   - parse_command/1
│   │   - generate_msg_id/0
│   │
│   ├── erwind_tcp_sup.erl
│   ├── erwind_tcp_listener.erl
│   ├── erwind_acceptor.erl
│   ├── erwind_connection.erl
│   │   - gen_statem 状态机
│   │   - 状态: wait_identify -> authenticated -> subscribed
│   │
│   ├── erwind_diskqueue.erl
│   ├── erwind_diskqueue_sup.erl
│   ├── erwind_backend_queue.erl
│   │
│   ├── erwind_topic_sup.erl
│   ├── erwind_topic.erl
│   ├── erwind_channel_sup.erl
│   ├── erwind_channel.erl
│   │
│   ├── erwind_http_sup.erl
│   ├── erwind_http_api.erl
│   ├── erwind_stats.erl
│   └── erwind_lookupd.erl
│
├── include/
│   ├── erwind.hrl         %% 公共头文件
│   └── erwind_protocol.hrl %% 协议相关定义
│
├── config/
│   └── sys.config
│
├── test/
│   ├── erwind_protocol_tests.erl
│   ├── erwind_topic_tests.erl
│   ├── erwind_channel_tests.erl
│   └── erwind_integration_tests.erl
│
├── rebar.config
└── README.md
```

## 关键数据结构

### 消息记录
```erlang
%% include/erwind_protocol.hrl

-record(nsq_message, {
    id :: binary(),          %% 16 bytes hex
    timestamp :: integer(),  %% milliseconds
    attempts :: integer(),   %% delivery attempts
    body :: binary()         %% payload
}).

-record(nsq_command, {
    type :: atom(),
    topic :: binary() | undefined,
    channel :: binary() | undefined,
    body :: binary() | undefined,
    params :: map() | undefined
}).
```

### Topic 状态
```erlang
-record(topic_state, {
    name :: binary(),
    channels = #{} :: #{binary() => pid()},
    backend :: pid(),
    paused = false :: boolean(),
    ephemeral = false :: boolean(),
    message_count = 0 :: integer()
}).
```

### Channel 状态
```erlang
-record(channel_state, {
    topic :: binary(),
    name :: binary(),
    consumers = #{} :: #{pid() => #consumer{}}},
    memory_queue :: queue:queue(),
    backend :: pid(),
    depth = 0 :: integer(),
    paused = false :: boolean()
}).

-record(consumer, {
    pid :: pid(),
    rdy = 0 :: integer(),
    in_flight = 0 :: integer(),
    inflight_msgs = #{} :: #{binary() => #in_flight_msg{}}
}).
```

## 测试策略

### 单元测试
```erlang
%% 协议测试
protocol_encode_decode_test() ->
    Msg = #nsq_message{id = <<"1234567890abcdef">>,
                       timestamp = 1234567890,
                       attempts = 1,
                       body = <<"hello">>},
    Encoded = erwind_protocol:encode_message(Msg),
    {ok, {message, Decoded}, <<>>} = erwind_protocol:decode_frame(Encoded),
    ?assertEqual(Msg#nsq_message.body, Decoded).

%% Topic 测试
topic_publish_test() ->
    {ok, Topic} = erwind_topic:start_link(<<"test">>),
    ok = erwind_topic:publish(Topic, <<"message">>),
    Stats = erwind_topic:get_stats(Topic),
    ?assertEqual(1, maps:get(message_count, Stats)).
```

### 集成测试
```erlang
%% 端到端测试
pub_sub_test() ->
    %% 启动应用
    application:start(erwind),
    
    %% 创建 Topic 和 Channel
    {ok, Topic} = erwind_topic_manager:create_topic(<<"test">>),
    {ok, Channel} = erwind_topic:get_channel(Topic, <<"ch">>),
    
    %% 发布消息
    ok = erwind_topic:publish(Topic, <<"hello">>),
    
    %% 验证 Channel 收到消息
    timer:sleep(100),
    Stats = erwind_channel:get_stats(Channel),
    ?assertEqual(1, maps:get(depth, Stats)).
```

### 压力测试
```bash
# 使用 nsq 自带的工具测试
$ nsq_pub -n 100000 -s 1024 localhost:4150 test_topic

# 使用自定义 Erlang 客户端测试
$ erl -pa ebin -s erwind_bench
```

## 性能目标

| 指标 | 目标值 |
|------|--------|
| 单节点吞吐量 | 100,000 msg/s |
| 延迟 (P99) | < 10ms |
| 内存使用 | < 4GB |
| 并发连接 | 10,000+ |
| 启动时间 | < 5s |

## 故障场景

| 场景 | 预期行为 |
|------|----------|
| Topic 崩溃 | 自动重启，恢复磁盘消息 |
| Channel 崩溃 | 自动重启，消费者重新订阅 |
| Consumer 断开 | 消息重新入队 |
| 磁盘满 | 暂停写入，返回错误 |
| 内存不足 | 消息写入磁盘 |
| 网络分区 | 等待恢复，消息不丢失 |
