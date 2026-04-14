# Erwind 项目计划文档

本文档包含 Erwind（Erlang NSQ Daemon）的完整实现计划。

## 文档索引

| 编号 | 文档 | 描述 |
|------|------|------|
| 00 | [overview.md](00_overview.md) | 项目概述和架构设计 |
| 01 | [tcp_listener.md](01_tcp_listener.md) | TCP 监听器模块 |
| 02 | [protocol.md](02_protocol.md) | NSQ 协议编解码 |
| 03 | [topic.md](03_topic.md) | Topic 模块 |
| 04 | [channel.md](04_channel.md) | Channel 模块（协调器） |
| 13 | [consumer_manager.md](13_consumer_manager.md) | 消费者管理器 |
| 14 | [inflight_tracker.md](14_inflight_tracker.md) | 在途消息跟踪器 |
| 15 | [delayed_queue.md](15_delayed_queue.md) | 延迟队列（时间轮） |
| 05 | [backend_queue.md](05_backend_queue.md) | Backend 队列模块 |
| 16 | [gc.md](16_gc.md) | 垃圾回收模块 |
| 06 | [http_api.md](06_http_api.md) | HTTP API 模块 |
| 07 | [nsqlookupd_client.md](07_nsqlookupd_client.md) | NSQLookupd 客户端 |
| 08 | [stats.md](08_stats.md) | 统计模块 |
| 09 | [supervision_tree.md](09_supervision_tree.md) | 监督树设计 |
| 10 | [application.md](10_application.md) | OTP 应用模块 |
| 11 | [detailed_analysis.md](11_detailed_analysis.md) | 深度架构分析与模块拆分优化 |
| 12 | [module_dependencies.md](12_module_dependencies.md) | 模块依赖关系详解 |
| 99 | [implementation_plan.md](99_implementation_plan.md) | 实施计划与路线图 |

## 快速导航

### 基础实现（必看）
- [00_overview.md](00_overview.md) - 先读这个了解整体架构
- [09_supervision_tree.md](09_supervision_tree.md) - 理解监督树设计
- [99_implementation_plan.md](99_implementation_plan.md) - 实施顺序

### 深度优化（进阶）
- [11_detailed_analysis.md](11_detailed_analysis.md) - 架构优化建议
- [12_module_dependencies.md](12_module_dependencies.md) - 依赖关系详解

## 实现路线图

### 第一阶段：基础框架
- [ ] 创建 OTP 应用骨架
- [ ] 实现监督树结构
- [ ] 实现配置管理

### 第二阶段：核心功能
- [ ] 实现 TCP 监听器
- [ ] 实现协议编解码
- [ ] 实现 Topic 模块
- [ ] 实现 Channel 模块

### 第三阶段：持久化
- [ ] 实现 Backend Queue
- [ ] 实现磁盘队列
- [ ] 实现消息恢复

### 第四阶段：管理接口
- [ ] 实现 HTTP API
- [ ] 实现统计模块
- [ ] 实现 nsqlookupd 客户端

### 第五阶段：优化和测试
- [ ] 性能测试
- [ ] 容错测试
- [ ] 文档完善

## 模块依赖图（v2 - 拆分后）

```
erwind_app
    ├── erwind_sup
    │   ├── erwind_topic_registry
    │   ├── erwind_tcp_sup
    │   │   ├── erwind_tcp_listener
    │   │   │   └── erwind_protocol
    │   │   ├── erwind_acceptor_pool_sup
    │   │   │   └── erwind_acceptor
    │   │   └── erwind_connection_sup
    │   │       └── erwind_connection
    │   ├── erwind_topic_sup
    │   │   └── erwind_topic
    │   │       ├── erwind_channel_sup
    │   │       │   └── erwind_channel (协调器)
    │   │       │       ├── erwind_consumer_manager [13]
    │   │       │       ├── erwind_inflight_tracker [14]
    │   │       │       ├── erwind_delayed_queue [15]
    │   │       │       ├── erwind_memory_queue
    │   │       │       └── erwind_backend_queue [05]
    │   │       └── erwind_backend_queue
    │   ├── erwind_storage_sup
    │   │   ├── erwind_diskqueue_sup
    │   │   │   └── erwind_diskqueue
    │   │   ├── erwind_backend_queue
    │   │   └── erwind_gc [16]
    │   ├── erwind_http_sup
    │   │   └── erwind_http_api
    │   ├── erwind_stats
    │   └── erwind_lookupd
    └── erwind_config
```

## 关键技术决策

1. **监督策略**: 使用分层监督树，确保单点故障不影响整体
2. **进程模型**: 每个 Topic/Channel/Consumer 独立进程
3. **消息存储**: 内存队列 + 磁盘队列混合存储
4. **协议兼容**: 完全兼容 NSQ TCP 协议 V2
5. **流量控制**: 使用 RDY 机制实现背压

## Erlang 风格指南

- 使用 OTP 行为（gen_server, gen_statem, supervisor）
- 遵循 "let it crash" 哲学
- 使用二进制数据优化性能
- ETS 表用于高速元数据查找
- 监督树实现容错
