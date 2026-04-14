# TCP 监听器模块 (erwind_tcp_listener)

## 功能概述

TCP 监听器是 Erwind 的入口点，负责接收生产者（Producer）和消费者（Consumer）的 TCP 连接。

## 原理详解

### NSQ TCP 协议 V2

NSQ 使用基于帧的协议（frame-based protocol）：

```
Frame 结构：
+------------------+----------+--------------------------------+
|   Frame Type     |  Size    |           Data                 |
|   (4 bytes)      |(4 bytes) |           (N bytes)            |
|   Big Endian     |Big Endian|                                |
+------------------+----------+--------------------------------+

Frame Type 值：
- 0: Response（响应）
- 1: Error（错误）
- 2: Message（消息，用于推送给消费者）
```

### 协议命令

客户端发送的命令（文本行协议）：

| 命令 | 参数 | 描述 |
|------|------|------|
| `IDENTIFY` | JSON body | 客户端认证和能力协商 |
| `AUTH` | secret | 认证 |
| `SUB` | topic channel | 订阅 channel（消费者） |
| `PUB` | topic body | 发布单条消息（生产者） |
| `MPUB` | topic [count] body | 批量发布消息 |
| `DPUB` | topic defer_time body | 延迟发布 |
| `RDY` | count | 更新 ready 计数（流量控制） |
| `FIN` | message_id | 消息处理完成 |
| `REQ` | message_id timeout | 重新入队（延迟重试） |
| `TOUCH` | message_id | 延长消息超时 |
| `CLS` | - | 优雅关闭 |
| `NOP` | - | 心跳响应 |

## Erlang 实现设计

### 模块结构

```erlang
-module(erwind_tcp_listener).
-behaviour(gen_server).

%% API
-export([start_link/1, stop/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {
    port :: inet:port_number(),
    listen_socket :: inet:socket(),
    acceptor_ref :: reference()
}).
```

### 监督者配置

```erlang
%% erwind_tcp_sup.erl
init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 10, period => 10},
          [#{id => erwind_tcp_listener,
              start => {erwind_tcp_listener, start_link, [Port]},
              restart => permanent,
              shutdown => 5000,
              type => worker,
              modules => [erwind_tcp_listener]},
           #{id => erwind_acceptor_pool,
              start => {erwind_acceptor_pool, start_link, []},
              restart => permanent,
              shutdown => 5000,
              type => supervisor,
              modules => [erwind_acceptor_pool]}]}}.
```

### 核心逻辑

#### 1. 监听启动

```erlang
init([Port]) ->
    Opts = [binary, {packet, raw}, {active, false}, {reuseaddr, true},
            {nodelay, true}, {backlog, 1024}],
    case gen_tcp:listen(Port, Opts) of
        {ok, ListenSocket} ->
            %% 启动 acceptor 池
            lists:foreach(fun(_) ->
                erwind_acceptor:start_link(ListenSocket)
            end, lists:seq(1, ?ACCEPTOR_POOL_SIZE)),
            {ok, #state{port = Port, listen_socket = ListenSocket}};
        {error, Reason} ->
            {stop, Reason}
    end.
```

#### 2. Acceptor 进程

```erlang
-module(erwind_acceptor).
-behaviour(gen_server).

%% Acceptor 循环
accept_loop(ListenSocket) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} ->
            %% 启动新连接处理进程
            {ok, Pid} = erwind_connection_sup:start_connection(Socket),
            gen_tcp:controlling_process(Socket, Pid),
            erwind_connection:activate(Pid),
            %% 继续接受新连接
            accept_loop(ListenSocket);
        {error, closed} ->
            ok;
        {error, Reason} ->
            error_logger:error_msg("Accept failed: ~p~n", [Reason]),
            timer:sleep(100),
            accept_loop(ListenSocket)
    end.
```

#### 3. 连接进程状态机

```erlang
-module(erwind_connection).
-behaviour(gen_statem).

%% 状态定义
callback_mode() -> state_functions.

%% 状态：等待 IDENTIFY
wait_identify(enter, _OldState, _Data) ->
    {keep_state_and_data, [{state_timeout, ?IDENTIFY_TIMEOUT, timeout}]};

wait_identify(info, {tcp, Socket, Data}, #{socket := Socket} = Data) ->
    case parse_command(Data) of
        {identify, Params} ->
            case validate_identify(Params) of
                ok ->
                    send_response(Socket, <<"OK">>),
                    {next_state, authenticated, NewData};
                {error, Reason} ->
                    send_error(Socket, Reason),
                    {stop, normal}
            end;
        _ ->
            send_error(Socket, e_invalid),
            {keep_state, Data}
    end.

%% 状态：等待认证/命令
authenticated(info, {tcp, Socket, RawData}, #{socket := Socket} = Data) ->
    case parse_command(RawData) of
        {pub, Topic, MsgBody} ->
            handle_publish(Topic, MsgBody, Data);
        {sub, Topic, Channel} ->
            handle_subscribe(Topic, Channel, Data);
        {rdy, Count} ->
            handle_ready(Count, Data);
        {fin, MsgId} ->
            handle_finish(MsgId, Data);
        {req, MsgId, Timeout} ->
            handle_requeue(MsgId, Timeout, Data);
        _ ->
            send_error(Socket, e_invalid),
            {keep_state, Data}
    end.

%% 状态：消费者订阅中
subscribed(info, {tcp, Socket, RawData}, Data) ->
    %% 处理 RDY, FIN, REQ, TOUCH 等命令
    ...;
subscribed(info, {deliver_message, Msg}, Data) ->
    %% 收到待投递消息
    deliver_message(Msg, Data).
```

### 流量控制（Flow Control）

NSQ 使用 RDY 机制实现背压（backpressure）：

```erlang
-record(consumer_state, {
    rdy_count = 0 :: non_neg_integer(),      %% 当前 ready 计数
    in_flight = #{} :: #{binary() => #msg{}}, %% 在途消息
    msg_timeout :: pos_integer(),             %% 消息超时时间
    max_rdy :: pos_integer()                  %% 最大 ready 值
}).

%% 更新 RDY
deupdate_rdy(Count, State) when Count > State#consumer_state.max_rdy ->
    {error, e_invalid_rdy};
update_rdy(Count, State) ->
    NewState = State#consumer_state{rdy_count = Count},
    %% 触发消息投递
    maybe_deliver_messages(NewState).

%% 检查是否可以投递
maybe_deliver_messages(#consumer_state{rdy_count = 0} = State) ->
    {ok, State};
maybe_deliver_messages(State) ->
    case erwind_channel:get_message() of
        {ok, Msg} ->
            send_message(Msg, State),
            maybe_deliver_messages(State#consumer_state{rdy_count = State#consumer_state.rdy_count - 1});
        empty ->
            {ok, State}
    end.
```

## 依赖关系

### 依赖的模块
- `erwind_topic` - 发布消息时需要查找/创建 topic
- `erwind_channel` - 订阅时需要操作 channel
- `erwind_stats` - 记录连接统计

### 被依赖的模块
- `erwind_sup` - 被根监督者启动

## 接口定义

```erlang
%% 启动监听
-spec start_link(Port :: inet:port_number()) -> {ok, pid()} | {error, term()}.

%% 获取监听端口
-spec get_port() -> inet:port_number().

%% 获取活跃连接数
-spec get_connection_count() -> non_neg_integer().
```

## 配置参数

```erlang
%% 在 erwind.app.src 或 sys.config 中
{erwind_tcp, [
    {port, 4150},                    %% 监听端口（NSQ 默认 4150）
    {acceptor_pool_size, 10},        %% Acceptor 进程池大小
    {max_connections, 10000},        %% 最大连接数
    {identify_timeout, 10000},       %% IDENTIFY 超时（毫秒）
    {heartbeat_interval, 30000},     %% 心跳间隔（毫秒）
    {msg_timeout, 60000},            %% 消息超时时间（毫秒）
    {max_rdy_count, 2500}            %% 最大 RDY 计数
]}.
```
