%% erwind_tcp_listener.erl
%% TCP 监听器模块 - Erwind 的入口点
%% 负责接收生产者和消费者的 TCP 连接

-module(erwind_tcp_listener).
-behaviour(gen_server).


%% API
-export([start_link/1, stop/0, get_port/0, get_connection_count/0, get_listen_socket/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include_lib("erwind/include/erwind.hrl").

-record(state, {
    port :: inet:port_number(),
    listen_socket :: inet:socket() | undefined
}).

%% =============================================================================
%% API
%% =============================================================================

%% 启动 TCP 监听器
-spec start_link(Port :: inet:port_number()) -> gen_server:start_ret().
start_link(Port) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Port], []).

%% 停止 TCP 监听器
-spec stop() -> ok.
stop() ->
    gen_server:stop(?MODULE).

%% 获取监听端口
-spec get_port() -> inet:port_number().
get_port() ->
    Port = gen_server:call(?MODULE, get_port),
    true = is_integer(Port),
    Port.

%% 获取监听 socket
-spec get_listen_socket() -> inet:socket() | undefined.
get_listen_socket() ->
    Socket = gen_server:call(?MODULE, get_listen_socket),
    true = (Socket =:= undefined orelse is_port(Socket)),
    Socket.

%% 获取活跃连接数
-spec get_connection_count() -> non_neg_integer().
get_connection_count() ->
    case ets:info(erwind_connections, size) of
        undefined -> 0;
        Size when is_integer(Size) -> Size;
        _ -> 0
    end.

%% =============================================================================
%% gen_server callbacks
%% =============================================================================

init([Port]) ->
    process_flag(trap_exit, true),

    %% TCP 监听选项
    Opts = [
        binary,                    %% 二进制模式
        {packet, raw},             %% 原始数据包
        {active, false},           %% 被动模式（需显式接收）
        {reuseaddr, true},         %% 地址复用
        {nodelay, true},           %% 禁用 Nagle 算法
        {backlog, 1024},           %% 连接队列长度
        {keepalive, true}          %% TCP keepalive
    ],

    case gen_tcp:listen(Port, Opts) of
        {ok, ListenSocket} ->
            logger:info("TCP listener started on port ~p~n", [Port]),

            %% 初始化 ETS 表用于连接计数
            ets:new(erwind_connections, [public, named_table, set,
                     {read_concurrency, true}, {write_concurrency, true}]),

            {ok, #state{
                port = Port,
                listen_socket = ListenSocket
            }};

        {error, Reason} ->
            logger:error("Failed to start TCP listener: ~p~n", [Reason]),
            {stop, Reason}
    end.

handle_call(get_port, _From, #state{port = Port} = State) ->
    {reply, Port, State};

handle_call(get_listen_socket, _From, #state{listen_socket = Socket} = State) ->
    {reply, Socket, State};

handle_call(get_connection_count, _From, State) ->
    Count = case ets:info(erwind_connections) of
        undefined -> 0;
        _ -> ets:info(erwind_connections, size)
    end,
    {reply, Count, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{listen_socket = undefined}) ->
    ok;

terminate(_Reason, #state{listen_socket = ListenSocket}) ->
    %% 关闭监听 socket
    gen_tcp:close(ListenSocket),
    logger:info("TCP listener stopped~n"),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
