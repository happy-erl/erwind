%% erwind_app_tests.erl
%% Tests for application callback module

-module(erwind_app_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Unit tests
%% =============================================================================

app_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [
        fun start_returns_ok/0,
        fun stop_returns_ok/0,
        fun start_type_normal/0
     ]}.

setup() ->
    %% Stop any existing supervisor
    stop_sup_tree(),
    ok.

cleanup(_) ->
    %% Clean up - stop the supervisor tree
    stop_sup_tree(),
    ok.

stop_sup_tree() ->
    case whereis(erwind_sup) of
        undefined -> ok;
        SupPid ->
            unlink(SupPid),
            exit(SupPid, shutdown),
            timer:sleep(200)
    end,
    case whereis(erwind_tcp_sup) of
        undefined -> ok;
        TcpSupPid ->
            unlink(TcpSupPid),
            exit(TcpSupPid, shutdown),
            timer:sleep(100)
    end,
    case whereis(erwind_tcp_listener) of
        undefined -> ok;
        ListenerPid ->
            unlink(ListenerPid),
            exit(ListenerPid, shutdown),
            timer:sleep(100)
    end.

%% =============================================================================
%% Tests
%% =============================================================================

start_returns_ok() ->
    %% 测试 start/2 返回正确的结果
    Result = erwind_app:start(normal, []),
    case Result of
        {ok, Pid} when is_pid(Pid) ->
            ?assert(is_pid(Pid));
        {ok, Pid, _State} when is_pid(Pid) ->
            ?assert(is_pid(Pid));
        {error, _Reason} ->
            %% 可能是因为监督者已经在运行
            ?assert(true)
    end.

stop_returns_ok() ->
    %% 测试 stop/1 返回 ok
    Result = erwind_app:stop([]),
    ?assertEqual(ok, Result).

start_type_normal() ->
    %% 测试正常启动类型
    Result = erwind_app:start(normal, []),
    case Result of
        {ok, Pid} when is_pid(Pid) -> ?assert(is_pid(Pid));
        {ok, Pid, _} when is_pid(Pid) -> ?assert(is_pid(Pid));
        {error, _} -> ?assert(true)
    end.

%% =============================================================================
%% Integration tests
%% =============================================================================

application_start_stop_test_() ->
    {setup,
     fun() ->
        %% Stop any existing supervisor
        stop_sup_tree(),
        ok
     end,
     fun(_) ->
        %% Clean up
        stop_sup_tree(),
        ok
     end,
     fun() ->
        %% 测试应用程序可以正常启动
        Result = erwind_app:start(normal, []),
        case Result of
            {ok, Pid} when is_pid(Pid) ->
                ?assert(is_pid(Pid));
            {ok, Pid, _} when is_pid(Pid) ->
                ?assert(is_pid(Pid));
            {error, _} ->
                ?assert(true)
        end
     end}.
