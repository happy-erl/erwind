%% erwind_acceptor.erl
%% Acceptor 进程 - 负责接受新连接

-module(erwind_acceptor).
-behaviour(gen_server).

%% API
-export([start_link/1]).

%% Export for testing
-export([format_addr/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {
    id :: integer()
}).

-define(ACCEPT_RETRY_DELAY, 100).
-define(MAX_CONNECTIONS, 10000).

%% =============================================================================
%% API
%% =============================================================================

%% 启动 acceptor 进程
-spec start_link(Id :: integer()) -> gen_server:start_ret().
start_link(Id) ->
    gen_server:start_link(?MODULE, [Id], []).

%% =============================================================================
%% gen_server callbacks
%% =============================================================================

init([Id]) ->
    process_flag(trap_exit, true),
    logger:info("Acceptor ~p starting", [Id]),
    %% 延迟启动接受循环，确保 listener 已准备好
    erlang:send_after(100, self(), start_accepting),
    {ok, #state{id = Id}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(start_accepting, #state{id = Id} = State) ->
    case erwind_tcp_listener:get_listen_socket() of
        undefined ->
            logger:error("Acceptor ~p: listen socket not available, retrying...", [Id]),
            erlang:send_after(500, self(), start_accepting),
            {noreply, State};
        ListenSocket ->
            logger:info("Acceptor ~p started accepting connections", [Id]),
            %% 在新进程中运行接受循环，避免阻塞 gen_server
            spawn_link(fun() -> accept_loop(ListenSocket, Id) end),
            {noreply, State}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =============================================================================
%% Internal functions
%% =============================================================================

%% Acceptor 循环 - 持续接受新连接
accept_loop(ListenSocket, Id) ->
    case check_connection_limit() of
        true ->
            do_accept(ListenSocket, Id);
        false ->
            %% 连接数超限，等待后重试
            timer:sleep(1000),
            accept_loop(ListenSocket, Id)
    end.

%% 执行 accept
do_accept(ListenSocket, Id) ->
    case gen_tcp:accept(ListenSocket, 5000) of
        {ok, Socket} ->
            handle_new_connection(Socket),
            accept_loop(ListenSocket, Id);

        {error, timeout} ->
            %% 超时，继续循环
            accept_loop(ListenSocket, Id);

        {error, closed} ->
            logger:info("Acceptor ~p: listen socket closed", [Id]),
            ok;

        {error, Reason} ->
            logger:error("Acceptor ~p: accept failed: ~p", [Id, Reason]),
            timer:sleep(?ACCEPT_RETRY_DELAY),
            accept_loop(ListenSocket, Id)
    end.

%% 处理新连接
handle_new_connection(Socket) ->
    %% 获取客户端信息
    {ok, {PeerAddr, PeerPort}} = inet:peername(Socket),
    {ok, {LocalAddr, LocalPort}} = inet:sockname(Socket),

    %% 格式化地址（处理 local/unspec 等特殊地址）
    PeerAddrStr = format_addr(PeerAddr),
    LocalAddrStr = format_addr(LocalAddr),

    logger:info("New connection from ~s:~p to ~s:~p",
        [PeerAddrStr, PeerPort, LocalAddrStr, LocalPort]),

    %% 启动新连接处理进程（通过监督者）
    case erwind_connection_sup:start_connection(Socket) of
        {ok, Pid} when is_pid(Pid) ->
            %% 将 socket 控制权转移给连接进程
            case gen_tcp:controlling_process(Socket, Pid) of
                ok ->
                    %% 激活连接（开始接收数据）
                    erwind_connection:activate(Pid),
                    %% 记录连接
                    ets:insert(erwind_connections, {Pid, #{peer => {PeerAddr, PeerPort}, time => erlang:system_time(second)}});
                {error, _Reason} ->
                    gen_tcp:close(Socket)
            end;

        {error, Reason} ->
            logger:error("Failed to start connection handler: ~p", [Reason]),
            gen_tcp:close(Socket)
    end.

%% 检查连接数限制
check_connection_limit() ->
    MaxConns = case application:get_env(erwind, max_connections) of
        {ok, M} when is_integer(M), M > 0 -> M;
        _ -> ?MAX_CONNECTIONS
    end,

    CurrentCount = case ets:info(erwind_connections) of
        undefined -> 0;
        _ -> ets:info(erwind_connections, size)
    end,

    CurrentCount < MaxConns.

%% 格式化 IP 地址（处理特殊地址类型）
format_addr(local) -> "local";
format_addr(unspec) -> "unspec";
format_addr(Addr) when is_tuple(Addr) -> inet:ntoa(Addr);
format_addr(Addr) -> io_lib:format("~p", [Addr]).
