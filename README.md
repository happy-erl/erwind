# Erwind

Erwind 是用 Erlang/OTP 实现的 NSQD（NSQ 消息队列核心组件）。

## 特性

- 完全兼容 NSQ TCP 协议 V2
- 支持 HTTP 管理 API
- 内存 + 磁盘混合队列
- 消息持久化
- 服务发现（nsqlookupd 集成）
- 流量控制（RDY 机制）
- 消息超时与重传
- 延迟投递
- 实时统计（StatsD/Prometheus）

## 架构

```
Producer/Consumer <- TCP Protocol -> erwind_tcp_listener
                                           |
                              +------------+------------+
                              |                         |
                        erwind_topic             erwind_http_api
                              |
                    +---------+---------+
                    |                   |
               erwind_channel      erwind_backend_queue
                    |
            erwind_consumer
```

## 快速开始

### 编译

```bash
$ rebar3 compile
```

### 启动

```bash
$ rebar3 shell
```

### 发布消息

```bash
$ echo "hello" | nsq_pub -topic=test localhost:4150
```

### 消费消息

```bash
$ nsq_sub -topic=test -channel=worker localhost:4150
```

## 配置

```erlang
%% config/sys.config
{erwind, [
    {tcp_port, 4150},
    {http_port, 4151},
    {data_dir, "/var/lib/erwind"},
    {nsqlookupd_tcp_addresses, ["localhost:4160"]}
]}.
```

## 项目文档

详细设计文档位于 [.plan/](.plan/) 目录：

| 文档 | 描述 |
|------|------|
| [00_overview.md](.plan/00_overview.md) | 项目概述和架构设计 |
| [01_tcp_listener.md](.plan/01_tcp_listener.md) | TCP 监听器模块 |
| [02_protocol.md](.plan/02_protocol.md) | NSQ 协议编解码 |
| [03_topic.md](.plan/03_topic.md) | Topic 模块 |
| [04_channel.md](.plan/04_channel.md) | Channel 模块 |
| [05_backend_queue.md](.plan/05_backend_queue.md) | Backend 队列模块 |
| [06_http_api.md](.plan/06_http_api.md) | HTTP API 模块 |
| [07_nsqlookupd_client.md](.plan/07_nsqlookupd_client.md) | NSQLookupd 客户端 |
| [08_stats.md](.plan/08_stats.md) | 统计模块 |
| [09_supervision_tree.md](.plan/09_supervision_tree.md) | 监督树设计 |
| [10_application.md](.plan/10_application.md) | OTP 应用模块 |
| [99_implementation_plan.md](.plan/99_implementation_plan.md) | 实施计划 |

## 模块依赖图

```
erwind_app
└── erwind_sup
    ├── erwind_topic_registry
    ├── erwind_tcp_sup
    │   ├── erwind_tcp_listener
    │   ├── erwind_acceptor_pool_sup
    │   └── erwind_connection_sup
    ├── erwind_topic_sup
    │   └── erwind_topic
    │       ├── erwind_channel_sup
    │       │   └── erwind_channel
    │       └── erwind_backend_queue
    ├── erwind_http_sup
    │   └── erwind_http_api
    ├── erwind_stats
    └── erwind_lookupd
```

## 实现路线图

1. **Phase 1**: 基础框架（OTP 应用、监督树）
2. **Phase 2**: 协议层（TCP 协议编解码）
3. **Phase 3**: 网络层（TCP 监听器、连接处理）
4. **Phase 4**: 存储层（磁盘队列、Backend Queue）
5. **Phase 5**: 核心逻辑（Topic、Channel）
6. **Phase 6**: 管理接口（HTTP API、统计）
7. **Phase 7**: 测试与优化

## 许可证

MIT
