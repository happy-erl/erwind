# Application 模块 (erwind_app)

## 功能概述

Application 模块是 OTP 应用的入口点，负责应用的启动、停止和配置管理。

## Erlang 实现

### 应用模块

```erlang
-module(erwind_app).
-behaviour(application).

-export([start/2, stop/1, version/0]).

%% 应用启动回调
start(_StartType, _StartArgs) ->
    %% 初始化日志
    ok = init_logging(),
    
    %% 加载配置
    ok = load_config(),
    
    %% 创建数据目录
    ok = init_data_dir(),
    
    %% 启动根监督者
    case erwind_sup:start_link() of
        {ok, Pid} ->
            error_logger:info_msg("Erwind started successfully"),
            {ok, Pid};
        {error, Reason} ->
            error_logger:error_msg("Erwind failed to start: ~p", [Reason]),
            {error, Reason}
    end.

%% 应用停止回调
stop(_State) ->
    error_logger:info_msg("Erwind stopped"),
    ok.

%% 获取版本号
version() ->
    {ok, Vsn} = application:get_key(erwind, vsn),
    list_to_binary(Vsn).

%% 初始化日志
init_logging() ->
    %% 配置 lager 或内置 error_logger
    ok.

%% 加载配置
load_config() ->
    %% 从 sys.config 加载配置
    case application:get_env(erwind, tcp_port) of
        undefined -> application:set_env(erwind, tcp_port, 4150);
        _ -> ok
    end,
    
    case application:get_env(erwind, http_port) of
        undefined -> application:set_env(erwind, http_port, 4151);
        _ -> ok
    end,
    
    ok.

%% 初始化数据目录
init_data_dir() ->
    DataDir = application:get_env(erwind, data_dir, "/var/lib/erwind"),
    ok = filelib:ensure_dir(DataDir ++ "/"),
    ok.
```

### App 资源文件

```erlang
%% erwind.app.src
{application, erwind, [
    {description, "Erlang NSQ daemon"},
    {vsn, "0.1.0"},
    {registered, [
        erwind_sup,
        erwind_tcp_sup,
        erwind_tcp_listener,
        erwind_topic_sup,
        erwind_stats,
        erwind_lookupd
    ]},
    {mod, {erwind_app, []}},
    {applications, [
        kernel,
        stdlib,
        sasl,
        crypto,
        asn1,
        public_key,
        ssl,
        inets,
        ranch,
        cowboy,
        jsx,
        hackney
    ]},
    {env, [
        %% TCP 配置
        {tcp_port, 4150},
        {tcp_acceptors, 10},
        {tcp_max_connections, 10000},
        
        %% HTTP 配置
        {http_port, 4151},
        
        %% Topic/Channel 配置
        {max_topic_size, 32},
        {max_channel_size, 32},
        {max_msg_size, 1048576},
        {max_msg_timeout, 900000},
        
        %% Backend 配置
        {data_dir, "/var/lib/erwind"},
        {max_bytes_per_file, 104857600},
        {sync_every, 2500},
        
        %% Lookupd 配置
        {nsqlookupd_tcp_addresses, []},
        
        %% 统计配置
        {statsd_enabled, false},
        {prometheus_enabled, false}
    ]},
    {modules, []},
    {maintainers, []},
    {licenses, ["MIT"]},
    {links, []}
]}.
```

### 应用配置 (sys.config)

```erlang
%% config/sys.config
[
    {erwind, [
        %% TCP 监听配置
        {tcp_port, 4150},
        {tcp_acceptors, 10},
        {tcp_max_connections, 10000},
        
        %% HTTP API 配置
        {http_port, 4151},
        
        %% 消息队列配置
        {max_msg_size, 1048576},           %% 1MB
        {max_msg_timeout, 900000},          %% 15分钟
        {default_msg_timeout, 60000},       %% 1分钟
        {max_msg_attempts, 5},
        
        %% Topic/Channel 限制
        {max_topics, 100},
        {max_channels_per_topic, 100},
        {max_consumers_per_channel, 100},
        
        %% Backend Queue 配置
        {data_dir, "/var/lib/erwind"},
        {max_bytes_per_file, 104857600},    %% 100MB
        {max_memory_depth, 10000},
        {sync_every, 2500},
        {sync_timeout, 2000},
        
        %% Lookupd 配置
        {nsqlookupd_tcp_addresses, [
            "localhost:4160"
        ]},
        {broadcast_address, "localhost"},
        
        %% 统计配置
        {stats_enabled, true},
        {statsd_enabled, false},
        {statsd_host, "localhost"},
        {statsd_port, 8125},
        {prometheus_enabled, false},
        {prometheus_port, 9150},
        
        %% 日志配置
        {log_level, info},
        {log_dir, "/var/log/erwind"}
    ]},
    
    %% SASL 配置
    {sasl, [
        {sasl_error_logger, {file, "/var/log/erwind/sasl.log"}},
        {errlog_type, error},
        {error_logger_mf_dir, "/var/log/erwind"},
        {error_logger_mf_maxbytes, 10485760},  %% 10MB
        {error_logger_mf_maxfiles, 10}
    ]},
    
    %% Cowboy 配置
    {cowboy, [
        {max_connections, 1000},
        {idle_timeout, 60000}
    ]},
    
    %% Hackney 配置
    {hackney, [
        {timeout, 5000},
        {max_connections, 50}
    ]}
].
```

### 环境变量支持

```erlang
%% 从环境变量加载配置
load_env_config() ->
    %% ERWIND_TCP_PORT
    case os:getenv("ERWIND_TCP_PORT") of
        false -> ok;
        Port -> 
            {ok, PortNum} = string:to_integer(Port),
            application:set_env(erwind, tcp_port, PortNum)
    end,
    
    %% ERWIND_HTTP_PORT
    case os:getenv("ERWIND_HTTP_PORT") of
        false -> ok;
        Port -> 
            {ok, PortNum} = string:to_integer(Port),
            application:set_env(erwind, http_port, PortNum)
    end,
    
    %% ERWIND_DATA_DIR
    case os:getenv("ERWIND_DATA_DIR") of
        false -> ok;
        Dir -> application:set_env(erwind, data_dir, Dir)
    end,
    
    %% ERWIND_LOOKUPD_ADDRS
    case os:getenv("ERWIND_LOOKUPD_ADDRS") of
        false -> ok;
        Addrs -> 
            AddrList = string:split(Addrs, ",", all),
            application:set_env(erwind, nsqlookupd_tcp_addresses, AddrList)
    end,
    
    ok.
```

## 依赖关系

### 依赖的外部库

```erlang
%% rebar.config
{deps, [
    %% HTTP 服务器
    {cowboy, "2.9.0"},
    
    %% JSON 处理
    {jsx, "3.1.0"},
    
    %% HTTP 客户端
    {hackney, "1.18.1"},
    
    %% 日志（可选）
    {lager, "3.9.2"},
    
    %% 统计（可选）
    {statsderl, "0.4.5"},
    {prometheus, "4.8.1"},
    
    %% 测试
    {proper, "1.4.0"},
    {meck, "0.9.2"}
]}.
```

### OTP 依赖

- `kernel` - Erlang 核心
- `stdlib` - 标准库
- `sasl` - 系统架构支持库（监督报告）
- `crypto` - 加密（用于消息 ID）
- `ssl` - SSL/TLS 支持
- `inets` - HTTP 客户端

## 启动脚本

### 开发环境

```bash
#!/bin/bash
# scripts/start-dev.sh

erl -pa _build/default/lib/*/ebin \
    -config config/sys.config \
    -s erwind_app \
    -sname erwind@localhost
```

### 生产环境

```bash
#!/bin/bash
# bin/erwind

# 加载环境变量
if [ -f /etc/erwind/erwind.env ]; then
    source /etc/erwind/erwind.env
fi

# 启动 Erlang VM
exec erl \
    -pa $RELEASE_DIR/lib/*/ebin \
    -config $RELEASE_DIR/sys.config \
    -boot $RELEASE_DIR/start.boot \
    -sname erwind@$HOSTNAME \
    -setcookie $ERWIND_COOKIE \
    -kernel inet_dist_listen_min 9000 inet_dist_listen_max 9100 \
    +K true \
    +P 1000000 \
    +t 5000000 \
    +Q 100000 \
    +zdbbl 8192 \
    -s erwind_app
```

### 系统服务 (systemd)

```ini
# /etc/systemd/system/erwind.service
[Unit]
Description=Erwind - Erlang NSQ Daemon
After=network.target

[Service]
Type=simple
User=erwind
Group=erwind
EnvironmentFile=/etc/erwind/erwind.env
ExecStart=/opt/erwind/bin/erwind foreground
ExecStop=/opt/erwind/bin/erwind stop
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
```

## 配置热更新

```erlang
%% 运行时更新配置
-module(erwind_config).

-export([update/2, get/1, reload/0]).

%% 更新配置
update(Key, Value) ->
    application:set_env(erwind, Key, Value),
    notify_change(Key, Value).

%% 获取配置
get(Key) ->
    application:get_env(erwind, Key, undefined).

%% 重新加载配置文件
reload() ->
    {ok, [[ConfigFile]]} = init:get_argument(config),
    {ok, [Config]} = file:consult(ConfigFile ++ ".config"),
    ErwindConfig = proplists:get_value(erwind, Config),
    lists:foreach(fun({Key, Value}) ->
        application:set_env(erwind, Key, Value)
    end, ErwindConfig),
    ok.

%% 通知配置变更
notify_change(tcp_port, Port) ->
    erwind_tcp_listener:update_port(Port);
notify_change(http_port, Port) ->
    erwind_http_api:update_port(Port);
notify_change(_, _) ->
    ok.
```
