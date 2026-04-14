# 监督树设计 (Supervision Tree)

## 概述

Erlang/OTP 的监督树是系统的容错核心。Erwind 采用分层监督结构，确保单点故障不会影响整个系统。

## 监督树结构

```
                            +------------------+
                            |   erwind_app     |
                            |   (Application)  |
                            +--------+---------+
                                     |
                            +--------v---------+
                            |   erwind_sup     |
                            | (Root Supervisor)|
                            |  one_for_one     |
                            +--------+---------+
         +-------------------+--------+---------+-------------------+
         |                   |                   |                   |
+--------v---------+ +-------v--------+ +-------v--------+ +-------v--------+
| erwind_tcp_sup   | | erwind_topic   | | erwind_http_sup| | erwind_stats   |
| (TCP 监督者)     | | _registry      | | (HTTP 监督者)  | | (统计服务)     |
| rest_for_one     | | (Topic 注册表) | | one_for_one    | | one_for_one    |
+--------+---------+ +----------------+ +----------------+ +----------------+
         |
+--------v---------+ +----------------+
| erwind_tcp       | | erwind_acceptor|
| _listener        | | _pool_sup      |
| (监听进程)       | | (Acceptor 池)  |
+------------------+ +--------+-------+
                              |
                     +--------v--------+
                     | erwind_acceptor |
                     | (Acceptor 进程) |
                     +-----------------+
                              |
                     +--------v--------+
                     | erwind_protocol |
                     | (协议处理)      |
                     +-----------------+
```

## 分层监督结构

### 第一层：Root Supervisor

```erlang
%% erwind_sup.erl
-module(erwind_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 60
    },
    
    Children = [
        %% 1. Topic 注册表（必须先启动）
        #{
            id => erwind_topic_registry,
            start => {erwind_topic_registry, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker
        },
        
        %% 2. TCP 监督树
        #{
            id => erwind_tcp_sup,
            start => {erwind_tcp_sup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor
        },
        
        %% 3. HTTP API 监督树
        #{
            id => erwind_http_sup,
            start => {erwind_http_sup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor
        },
        
        %% 4. Backend Queue 监督树
        #{
            id => erwind_backend_sup,
            start => {erwind_backend_sup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor
        },
        
        %% 5. Stats 服务
        #{
            id => erwind_stats,
            start => {erwind_stats, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker
        },
        
        %% 6. Lookupd 客户端（可选）
        #{
            id => erwind_lookupd,
            start => {erwind_lookupd, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker
        }
    ],
    
    {ok, {SupFlags, Children}}.
```

### 第二层：TCP 监督树

```erlang
%% erwind_tcp_sup.erl
-module(erwind_tcp_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

init([]) ->
    SupFlags = #{
        %% rest_for_one: 如果 listener 重启，所有 acceptor 也重启
        strategy => rest_for_one,
        intensity => 10,
        period => 60
    },
    
    Children = [
        %% 1. TCP 监听器
        #{
            id => erwind_tcp_listener,
            start => {erwind_tcp_listener, start_link, [4150]},
            restart => permanent,
            shutdown => 5000,
            type => worker
        },
        
        %% 2. Acceptor 池监督者
        #{
            id => erwind_acceptor_pool_sup,
            start => {erwind_acceptor_pool_sup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor
        },
        
        %% 3. 连接监督树
        #{
            id => erwind_connection_sup,
            start => {erwind_connection_sup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor
        }
    ],
    
    {ok, {SupFlags, Children}}.
```

### 第三层：Acceptor 池

```erlang
%% erwind_acceptor_pool_sup.erl
-module(erwind_acceptor_pool_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

init([]) ->
    SupFlags = #{
        %% one_for_one: 单个 acceptor 崩溃只重启它自己
        strategy => one_for_one,
        intensity => 60,
        period => 60
    },
    
    %% 动态启动 10 个 acceptor
    AcceptorSpecs = [
        #{
            id => {acceptor, N},
            start => {erwind_acceptor, start_link, [N]},
            restart => permanent,
            shutdown => 5000,
            type => worker
        }
        || N <- lists:seq(1, 10)
    ],
    
    {ok, {SupFlags, AcceptorSpecs}}.
```

### 动态 Topic/Channel 监督树

```erlang
%% erwind_topic_sup.erl
-module(erwind_topic_sup).
-behaviour(supervisor).

-export([start_link/0, start_topic/1, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% 动态启动 Topic
start_topic(TopicName) ->
    supervisor:start_child(?MODULE, [TopicName]).

init([]) ->
    SupFlags = #{
        %% simple_one_for_one: 动态子进程，统一规格
        strategy => simple_one_for_one,
        intensity => 100,
        period => 60
    },
    
    %% Topic 子进程规格
    TopicSpec = #{
        id => erwind_topic,
        start => {erwind_topic, start_link, []},
        restart => temporary,  %% Topic 可手动关闭
        shutdown => 5000,
        type => worker
    },
    
    {ok, {SupFlags, [TopicSpec]}}.
```

```erlang
%% erwind_channel_sup.erl
-module(erwind_channel_sup).
-behaviour(supervisor).

-export([start_link/1, start_channel/2, init/1]).

start_link(TopicName) ->
    supervisor:start_link(?MODULE, [TopicName]).

start_channel(SupPid, ChannelName) ->
    supervisor:start_child(SupPid, [ChannelName]).

init([TopicName]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 100,
        period => 60
    },
    
    ChannelSpec = #{
        id => erwind_channel,
        start => {erwind_channel, start_link, [TopicName]},
        restart => temporary,
        shutdown => 5000,
        type => worker
    },
    
    {ok, {SupFlags, [ChannelSpec]}}.
```

## 重启策略详解

### one_for_one

```
Before:              Child A crashes:
[ A ][ B ][ C ]      [ X ][ B ][ C ]
                         |
                         v
                    只重启 A
```

适用于独立进程，一个崩溃不影响其他。

### one_for_all

```
Before:              Child A crashes:
[ A ][ B ][ C ]      [ X ][ X ][ X ]
                         |
                         v
                    全部重启
```

适用于相互依赖的进程。

### rest_for_one

```
Before:              Child B crashes:
[ A ][ B ][ C ]      [ A ][ X ][ X ]
                              |
                              v
                         B 和后面的全部重启
```

适用于依赖链：A -> B -> C，B 依赖 A，C 依赖 B。

### simple_one_for_one

用于动态创建的子进程（如 Topic、Channel），所有子进程共享同一规格。

## 故障场景处理

### 场景 1: Topic 进程崩溃

```
1. Topic 进程异常退出
2. Channel Sup 检测到 'DOWN' 信号
3. Channel 和 Backend Queue 全部停止
4. Topic Sup 不自动重启（temporary）
5. 客户端重新发布时重新创建 Topic
```

### 场景 2: Acceptor 进程崩溃

```
1. 单个 Acceptor 崩溃
2. Acceptor Pool Sup 检测到并重启
3. 其他 Acceptor 继续接受连接
4. 系统恢复，无连接丢失
```

### 场景 3: TCP Listener 崩溃

```
1. Listener 崩溃
2. TCP Sup (rest_for_one) 重启 Listener
3. 同时重启所有 Acceptor
4. 短暂中断后恢复服务
```

### 场景 4: 整个节点崩溃

```
1. Erlang VM 崩溃
2. 操作系统重启进程
3. 从磁盘队列恢复消息
4. 重新向 nsqlookupd 注册
```

## 监控和告警

### 使用 observer 监控

```erlang
%% 启动 observer
observer:start().

%% 查看监督树
%% Applications -> erwind -> 右键 "Show supervision tree"
```

### 使用 sys 模块调试

```erlang
%% 查看监督者状态
sys:get_status(erwind_sup).

%% 查看子进程列表
supervisor:which_children(erwind_sup).

%% 统计重启次数
supervisor:get_callback_module(erwind_sup).
```

## 容错配置建议

```erlang
%% 生产环境建议配置
{supervisor, [
    %% 最大重启次数
    {max_restarts, 10},
    
    %% 重启窗口（秒）
    {max_seconds, 60},
    
    %% 进程关闭超时（毫秒）
    {shutdown_timeout, 5000},
    
    %% 是否捕获退出信号
    {trap_exit, true}
]}.
```
