# Erwind 项目概述

Erwind 是用 Erlang/OTP 复刻 NSQD（NSQ 消息队列核心组件）的实现。

## NSQ 核心概念

### 1. Topic（主题）
- 消息的逻辑通道
- 生产者将消息发布到特定 topic
- 一个 topic 可以有多个 channel

### 2. Channel（通道）
- 每个 topic 下的消息分发路径
- 类似于 Kafka 的 consumer group
- 消息会在 channel 之间复制，但在 channel 内竞争消费

### 3. Message（消息）
- 基本数据单元
- 包含 ID、时间戳、attempts（重试次数）、body
- 支持延迟投递

### 4. Backend Queue（后端队列）
- 消息持久化存储
- 内存队列 + 磁盘溢出（mem/disk混合）
- 支持 Go 风格的 diskqueue

## Erlang 架构设计原则

### OTP 设计模式
- 使用 supervision tree 实现容错
- gen_server 处理状态管理
- gen_statem 处理协议状态机
- ETS 表用于高速元数据查找

### 进程模型
```
erwind_sup (Application Supervisor)
├── erwind_tcp_listener_sup (TCP 监听器监督者)
│   └── erwind_tcp_listener (TCP 监听进程)
├── erwind_http_sup (HTTP API 监督者)
│   └── erwind_http_server (HTTP 服务进程)
├── erwind_topic_sup (Topic 监督者 - simple_one_for_one)
│   └── erwind_topic (Topic 进程)
│       └── erwind_channel_sup (Channel 监督者 - simple_one_for_one)
│           └── erwind_channel (Channel 进程)
│               └── erwind_backend_sup (Backend 监督者)
│                   └── erwind_backend_queue (队列进程)
├── erwind_stats (统计信息 gen_server)
├── erwind_lookupd (nsqlookupd 客户端)
└── erwind_diskqueue_sup (磁盘队列监督者)
    └── erwind_diskqueue (磁盘队列进程)
```

### 消息流
```
Producer -> TCP Protocol -> Topic -> Channel(s) -> Consumer(s)
                              |
                              v
                        Backend Queue (mem/disk)
```

## 模块依赖图

```
                            +------------------+
                            |   erwind_app     |
                            +--------+---------+
                                     |
                            +--------v---------+
                            |   erwind_sup     |
                            +--------+---------+
          +-----------------+--------+---------+------------------+
          |                          |                          |
+---------v---------+    +-----------v-----------+   +----------v----------+
| erwind_tcp_sup    |    |   erwind_topic_sup    |   |   erwind_http_sup   |
+---------+---------+    +-----------+-----------+   +----------+----------+
          |                          |                          |
+---------v---------+    +-----------v-----------+   +----------v----------+
| erwind_tcp_listener|   |    erwind_topic       |   |   erwind_http_server|
| erwind_protocol    |   +-----------+-----------+   +---------------------+
+---------+---------+                |
          |               +----------v-----------+
          |               |   erwind_channel_sup |
          |               +----------+-----------+
          |                          |
          |               +----------v-----------+
          |               |   erwind_channel     |
          |               +----------+-----------+
          |                          |
          |               +----------v-----------+
          |               | erwind_backend_queue |
          |               +----------+-----------+
          |                          |
          |               +----------v-----------+
          +-------------->|   erwind_consumer    |
                          +----------------------+
```

## 关键设计决策

### 1. 进程隔离
- 每个 Topic 一个进程
- 每个 Channel 一个进程（每个 Topic 下）
- 每个 Consumer 连接一个进程
- Backend Queue 独立进程

### 2. 容错设计
- Topic 崩溃不影响其他 Topic
- Channel 崩溃会丢失待处理消息，但会自动重启
- Consumer 连接断开自动清理资源
- 使用 supervisor 自动重启策略

### 3. 性能优化
- ETS 表存储 topic/channel 注册表
- 二进制数据零拷贝传递
- 使用 `gen_tcp` 的 `{active, N}` 模式控制流量
- 批量消息处理减少进程切换

### 4. 协议兼容
- 支持 NSQ TCP 协议（V2）
- 支持 HTTP 管理 API
- 支持与 nsqlookupd 集成
