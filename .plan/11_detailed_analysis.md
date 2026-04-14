# Erwind 深度架构分析与模块拆分优化

## 一、当前架构深度理解

### 1.1 核心数据流分析

```
Producer -> TCP -> Protocol -> Topic -> Channel -> Consumer
                              |          |
                              v          v
                          Backend    In-Flight
                          Queue      Queue
```

**关键洞察**：
- Topic 是消息分发的**复制点**（1:N 广播到所有 Channel）
- Channel 是消息投递的**竞争点**（1:1 选择消费者）
- Backend Queue 是 Topic 和 Channel 的**存储层**

### 1.2 当前模块分层

| 层级 | 模块 | 职责 |
|------|------|------|
| 接口层 | erwind_tcp_listener, erwind_http_api | 外部接口 |
| 协议层 | erwind_protocol | 数据编解码 |
| 核心层 | erwind_topic, erwind_channel | 业务逻辑 |
| 存储层 | erwind_backend_queue, erwind_diskqueue | 持久化 |
| 服务层 | erwind_stats, erwind_lookupd | 辅助服务 |

---

## 二、发现的问题与遗漏

### 2.1 关键遗漏模块

#### 1. erwind_message_router（消息路由）
**问题**：目前 Topic 直接负责消息路由到 Channel，职责过重
**需要**：
- 消息优先级路由
- 消息过滤（基于 tag/header）
- 死信队列（DLQ）处理
- 消息追踪

#### 2. erwind_consumer_manager（消费者管理）
**问题**：Channel 直接管理 consumers map，缺乏集中管理
**需要**：
- 消费者负载均衡算法
- 消费者健康检查
- 消费者断线检测和清理
- 消费者能力协商

#### 3. erwind_delayed_queue（延迟队列）
**问题**：延迟消息散落在 Topic/Channel 中，无统一管理
**需要**：
- 集中式延迟消息存储
- 时间轮（Time Wheel）调度
- 延迟消息持久化

#### 4. erwind_auth（认证授权）
**问题**：协议层提到 AUTH 命令，但无专门模块
**需要**：
- TLS/SSL 支持
- Token 认证
- ACL 权限控制
- Topic/Channel 级别权限

#### 5. erwind_cluster（集群协调）
**问题**：只有 lookupd 客户端，无集群内通信
**需要**：
- 节点间消息复制（HA）
- 分片（Sharding）支持
- 节点发现
- Leader 选举

#### 6. erwind_gc（垃圾回收）
**问题**：磁盘队列文件清理逻辑散落在 diskqueue
**需要**：
- 独立 GC 进程
- 过期消息清理
- 文件合并/压缩
- 存储配额管理

### 2.2 模块职责过重

#### erwind_channel 的问题
当前负责：
- 消费者管理
- 消息队列
- In-Flight 管理
- 超时检测
- 重入队处理

**拆分建议**：
```
erwind_channel (核心协调)
├── erwind_consumer_manager (消费者)
├── erwind_memory_queue (内存队列)
├── erwind_inflight_tracker (在途跟踪)
└── erwind_delayed_queue (延迟队列)
```

---

## 三、优化后的模块架构

### 3.1 新架构图

```
┌─────────────────────────────────────────────────────────────────────┐
│                           API Layer                                  │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────┐  │
│  │ TCP Interface   │  │ HTTP Interface  │  │ Admin Interface     │  │
│  │ (tcp_listener)  │  │ (http_api)      │  │ (management)        │  │
│  └────────┬────────┘  └─────────────────┘  └─────────────────────┘  │
└───────────┼─────────────────────────────────────────────────────────┘
            │
            v
┌─────────────────────────────────────────────────────────────────────┐
│                        Protocol Layer                                │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────┐  │
│  │ Frame Codec     │  │ Command Parser  │  │ Auth/ACL            │  │
│  │ (protocol)      │  │ (protocol)      │  │ (auth)              │  │
│  └─────────────────┘  └─────────────────┘  └─────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
            │
            v
┌─────────────────────────────────────────────────────────────────────┐
│                     Routing & Distribution                           │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────┐  │
│  │ Topic Registry  │  │ Message Router  │  │ Load Balancer       │  │
│  │ (topic_registry)│  │ (msg_router)    │  │ (load_balancer)     │  │
│  └─────────────────┘  └─────────────────┘  └─────────────────────┘  │
└───────────┬─────────────────────────────────────────────────────────┘
            │
            v
┌─────────────────────────────────────────────────────────────────────┐
│                       Core Logic Layer                               │
│                                                                      │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │ Topic (topic) - 消息分发器                                    │  │
│  │  - 消息路由到 Channels                                        │  │
│  │  - Channel 生命周期管理                                       │  │
│  └───────────────────────┬───────────────────────────────────────┘  │
│                          │                                          │
│                          v                                          │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │ Channel (channel) - 消费者组协调器                            │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐   │  │
│  │  │ ConsumerMgr │  │ MemoryQueue │  │ InflightTracker     │   │  │
│  │  │             │  │             │  │                     │   │  │
│  │  └─────────────┘  └─────────────┘  └─────────────────────┘   │  │
│  └───────────────────────┬───────────────────────────────────────┘  │
│                          │                                          │
│                          v                                          │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │ Delayed Queue (delayed_queue) - 延迟消息管理                  │  │
│  │  - 时间轮调度                                                 │  │
│  │  - 到期触发投递                                               │  │
│  └───────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
            │
            v
┌─────────────────────────────────────────────────────────────────────┐
│                       Storage Layer                                  │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────┐  │
│  │ Backend Queue   │  │ Disk Queue      │  │ GC Manager          │  │
│  │ (backend_q)     │  │ (diskqueue)     │  │ (gc)                │  │
│  │  - Mem/Disk混合 │  │  - 文件分段     │  │  - 过期清理         │  │
│  │  - Overflow控制 │  │  - 顺序IO       │  │  - 文件合并         │  │
│  └─────────────────┘  └─────────────────┘  └─────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
            │
            v
┌─────────────────────────────────────────────────────────────────────┐
│                       Service Layer                                  │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────┐  │
│  │ Stats Collector │  │ Lookupd Client  │  │ Cluster Manager     │  │
│  │ (stats)         │  │ (lookupd)       │  │ (cluster)           │  │
│  │  - ETS存储      │  │  - 服务发现     │  │  - 节点协调         │  │
│  │  - 速率计算     │  │  - 心跳注册     │  │  - 数据复制         │  │
│  └─────────────────┘  └─────────────────┘  └─────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

### 3.2 新增模块详细设计

#### 1. erwind_message_router（消息路由器）

```erlang
-module(erwind_message_router).
-behaviour(gen_server).

%% 职责：
%% 1. 消息路由规则管理
%% 2. 消息过滤
%% 3. 死信队列处理
%% 4. 消息追踪

-record(route_rule, {
    topic :: binary(),
    filter :: fun((#nsq_message{}) -> boolean()),
    target_channels :: [binary()],
    priority :: integer()
}).

%% API
-export([register_rule/2, unregister_rule/1, route/2]).
-export([enable_dlq/2, dlq_replay/2]).
```

#### 2. erwind_consumer_manager（消费者管理器）

```erlang
-module(erwind_consumer_manager).
-behaviour(gen_server).

%% 职责：
%% 1. 消费者注册/注销
%% 2. 负载均衡（轮询/一致性哈希）
%% 3. 健康检查
%% 4. 断线检测

-record(consumer_info, {
    pid :: pid(),
    rdy :: integer(),
    in_flight :: integer(),
    capabilities :: map(),
    last_active :: integer(),
    health :: healthy | unhealthy
}).

%% 负载均衡算法
-type balance_strategy() :: round_robin | consistent_hash | least_loaded.

%% API
-export([subscribe/2, unsubscribe/2, select_consumer/2]).
-export([update_rdy/3, get_consumer_stats/1]).
-export([set_balance_strategy/1, get_balance_strategy/0]).
```

#### 3. erwind_delayed_queue（延迟队列）

```erlang
-module(erwind_delayed_queue).
-behaviour(gen_server).

%% 职责：
%% 1. 延迟消息存储
%% 2. 时间轮调度
%% 3. 到期触发

%% 使用分层时间轮（Hierarchical Time Wheel）
%% 层级：1ms -> 1s -> 1min -> 1hour

-record(delayed_msg, {
    msg :: #nsq_message{},
    target_topic :: binary(),
    target_channel :: binary() | undefined,
    trigger_time :: integer()  %% 触发时间戳
}).

%% API
-export([schedule/4, cancel/2, get_pending_count/0]).
```

#### 4. erwind_inflight_tracker（在途消息跟踪）

```erlang
-module(erwind_inflight_tracker).
-behaviour(gen_server).

%% 职责：
%% 1. In-Flight 消息跟踪
%% 2. 超时检测
%% 3. 消息重传
%% 4. 消息 ACK/NACK

-record(inflight_entry, {
    msg_id :: binary(),
    msg :: #nsq_message{},
    consumer_pid :: pid(),
    deliver_time :: integer(),
    expire_time :: integer(),
    retry_count = 0 :: integer()
}).

%% API
-export([track/3, ack/2, nack/3, touch/2]).
-export([get_inflight_count/1, get_expired_msgs/1]).
```

#### 5. erwind_auth（认证授权）

```erlang
-module(erwind_auth).

%% 职责：
%% 1. TLS/SSL 连接管理
%% 2. Token 认证
%% 3. ACL 权限控制

-record(auth_context, {
    client_id :: binary(),
    token :: binary(),
    permissions :: #{topic => read | write | admin}
}).

%% API
-export([authenticate/2, authorize/3]).
-export([generate_token/1, verify_token/1]).
```

#### 6. erwind_cluster（集群管理）

```erlang
-module(erwind_cluster).
-behaviour(gen_server).

%% 职责：
%% 1. 节点发现
%% 2. 分片管理
%% 3. 数据复制
%% 4. Leader 选举

-record(cluster_node, {
    node :: node(),
    address :: string(),
    partitions :: [integer()],
    status :: active | inactive
}).

%% API
-export([join_cluster/1, leave_cluster/0]).
-export([get_partition_owner/1, replicate/3]).
```

#### 7. erwind_gc（垃圾回收）

```erlang
-module(erwind_gc).
-behaviour(gen_server).

%% 职责：
%% 1. 过期消息清理
%% 2. 磁盘文件合并
%% 3. 存储配额管理
%% 4. 压缩归档

-record(gc_policy, {
    ttl :: integer(),           %% 消息存活时间
    max_size :: integer(),      %% 最大存储大小
    compaction_ratio :: float() %% 压缩比例阈值
}).

%% API
-export([set_policy/2, trigger_gc/1, get_storage_stats/0]).
```

---

## 四、细化后的文件结构

```
src/
├── core/                          %% 核心逻辑层
│   ├── erwind_topic.erl
│   ├── erwind_topic_sup.erl
│   ├── erwind_topic_registry.erl
│   ├── erwind_channel.erl
│   ├── erwind_channel_sup.erl
│   ├── erwind_consumer_manager.erl
│   ├── erwind_message_router.erl
│   └── erwind_delayed_queue.erl
│
├── protocol/                      %% 协议层
│   ├── erwind_protocol.erl
│   ├── erwind_protocol_codec.erl  %% 编解码拆分
│   ├── erwind_command_parser.erl  %% 命令解析拆分
│   └── erwind_auth.erl
│
├── transport/                     %% 传输层
│   ├── erwind_tcp_listener.erl
│   ├── erwind_tcp_sup.erl
│   ├── erwind_acceptor.erl
│   ├── erwind_acceptor_pool_sup.erl
│   ├── erwind_connection.erl
│   ├── erwind_connection_sup.erl
│   ├── erwind_http_api.erl
│   └── erwind_http_sup.erl
│
├── storage/                       %% 存储层
│   ├── erwind_backend_queue.erl
│   ├── erwind_memory_queue.erl    %% 新增：纯内存队列
│   ├── erwind_diskqueue.erl
│   ├── erwind_diskqueue_sup.erl
│   ├── erwind_inflight_tracker.erl
│   └── erwind_gc.erl
│
├── services/                      %% 服务层
│   ├── erwind_stats.erl
│   ├── erwind_lookupd.erl
│   ├── erwind_cluster.erl
│   └── erwind_load_balancer.erl   %% 新增：负载均衡
│
├── utils/                         %% 工具模块
│   ├── erwind_config.erl
│   ├── erwind_logger.erl
│   ├── erwind_utils.erl
│   └── erwind_metrics.erl         %% 新增：指标收集
│
├── erwind_app.erl
├── erwind_sup.erl
└── erwind.app.src

include/
├── erwind.hrl                     %% 公共头文件
├── erwind_protocol.hrl            %% 协议相关
├── erwind_storage.hrl             %% 存储相关
└── erwind_types.hrl               %% 类型定义

config/
├── sys.config
├── erwind.schema                  %% 配置验证模式
└── vm.args                        %% VM 参数

test/
├── unit/
│   ├── protocol_tests.erl
│   ├── storage_tests.erl
│   └── core_tests.erl
├── integration/
│   ├── pub_sub_tests.erl
│   ├── cluster_tests.erl
│   └── failover_tests.erl
└── bench/
    ├── throughput_bench.erl
    └── latency_bench.erl
```

---

## 五、关键改进点

### 5.1 单一职责原则（SRP）

| 原模块 | 拆分后 | 职责 |
|--------|--------|------|
| erwind_channel | erwind_channel + consumer_mgr + inflight_tracker | 协调 vs 管理 vs 跟踪 |
| erwind_protocol | protocol_codec + command_parser | 编解码 vs 语义解析 |
| erwind_backend_queue | backend_queue + memory_queue | 混合 vs 纯内存 |
| erwind_diskqueue | diskqueue + gc | 存储 vs 清理 |

### 5.2 可测试性提升

每个小模块都有明确的输入输出，便于单元测试：

```erlang
%% erwind_inflight_tracker 单元测试示例
inflight_timeout_test() ->
    {ok, Pid} = erwind_inflight_tracker:start_link(),
    Msg = #nsq_message{id = <<"test1">>, body = <<"hello">>},
    
    %% 跟踪消息
    ok = erwind_inflight_tracker:track(Pid, self(), Msg, 100), %% 100ms超时
    
    %% 验证在途
    ?assertEqual(1, erwind_inflight_tracker:get_inflight_count(Pid)),
    
    %% 等待超时
    timer:sleep(150),
    
    %% 获取过期消息
    Expired = erwind_inflight_tracker:get_expired_msgs(Pid),
    ?assertEqual([Msg], Expired).
```

### 5.3 性能优化点

1. **内存队列**：分离纯内存队列，避免不必要的磁盘IO
2. **In-Flight 跟踪**：使用 ETS 而非 Map，提升并发性能
3. **延迟队列**：分层时间轮，O(1) 复杂度
4. **消息路由**：预编译过滤函数，减少运行时开销

---

## 六、实施优先级建议

### Phase 1: MVP（最小可用产品）
按原有规划实现基础功能，但保留扩展点。

### Phase 2: 稳定性增强
1. erwind_inflight_tracker - 分离 In-Flight 管理
2. erwind_consumer_manager - 更好的消费者管理
3. erwind_gc - 独立的垃圾回收

### Phase 3: 高级功能
1. erwind_delayed_queue - 延迟消息
2. erwind_auth - 安全认证
3. erwind_message_router - 消息路由

### Phase 4: 分布式
1. erwind_cluster - 集群支持
2. erwind_load_balancer - 负载均衡

---

## 七、NSQ 特性对比

| NSQ 特性 | 当前规划 | 增强后 |
|----------|----------|--------|
| Topic/Channel | ✅ | ✅ |
| 内存/Disk混合 | ✅ | ✅ (细化) |
| 延迟消息 | ⚠️ (简单实现) | ✅ (时间轮) |
| In-Flight | ⚠️ (Channel内) | ✅ (独立模块) |
| 死信队列 | ❌ | ✅ |
| 消息过滤 | ❌ | ✅ |
| 认证授权 | ❌ | ✅ |
| 集群/分片 | ❌ | ✅ |
| TLS | ❌ | ✅ |
| 消息追踪 | ❌ | ✅ |
