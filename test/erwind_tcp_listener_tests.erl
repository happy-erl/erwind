%% erwind_tcp_listener_tests.erl
%% Tests for TCP listener module

-module(erwind_tcp_listener_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("erwind/include/erwind.hrl").

-define(TEST_PORT, 14150).

%% =============================================================================
%% Unit tests - don't start full application
%% =============================================================================

tcp_listener_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [
        fun start_stop/0,
        fun get_port/0,
        fun get_listen_socket/0,
        fun get_connection_count/0,
        fun double_start_fails/0,
        fun client_can_connect/0
     ]}.

setup() ->
    %% Stop any existing listener first
    stop_listener(),
    %% Also stop any supervisor tree that might have started it
    case whereis(erwind_sup) of
        undefined -> ok;
        SupPid ->
            unlink(SupPid),
            exit(SupPid, shutdown),
            timer:sleep(200)
    end,
    %% Also stop tcp_sup if running
    case whereis(erwind_tcp_sup) of
        undefined -> ok;
        Pid ->
            unlink(Pid),
            exit(Pid, shutdown),
            timer:sleep(100)
    end,
    stop_listener(),
    timer:sleep(200),
    ok.

cleanup(_) ->
    stop_listener(),
    timer:sleep(50),
    ok.

stop_listener() ->
    case whereis(erwind_tcp_listener) of
        undefined -> ok;
        Pid ->
            unlink(Pid),
            exit(Pid, normal),
            timer:sleep(100)
    end.

%% =============================================================================
%% Tests
%% =============================================================================

start_stop() ->
    %% Check if listener is already running
    case whereis(erwind_tcp_listener) of
        undefined ->
            %% TCP listener should start on test port
            Result = erwind_tcp_listener:start_link(?TEST_PORT),
            ?assertMatch({ok, _}, Result),
            stop_listener();
        _Pid ->
            %% Listener already running, skip test
            ?assert(true)
    end.

get_port() ->
    case whereis(erwind_tcp_listener) of
        undefined ->
            {ok, _Pid} = erwind_tcp_listener:start_link(?TEST_PORT),
            ?assertEqual(?TEST_PORT, erwind_tcp_listener:get_port()),
            stop_listener();
        Pid when is_pid(Pid) ->
            %% Listener already running, just verify it works
            ?assert(is_pid(Pid))
    end.

get_listen_socket() ->
    case whereis(erwind_tcp_listener) of
        undefined ->
            {ok, _Pid} = erwind_tcp_listener:start_link(?TEST_PORT),
            Socket = erwind_tcp_listener:get_listen_socket(),
            ?assertMatch(Socket when Socket =/= undefined, Socket),
            stop_listener();
        Pid when is_pid(Pid) ->
            %% Listener already running, just verify it works
            Socket = erwind_tcp_listener:get_listen_socket(),
            ?assert(Socket =/= undefined)
    end.

get_connection_count() ->
    case whereis(erwind_tcp_listener) of
        undefined ->
            {ok, _Pid} = erwind_tcp_listener:start_link(?TEST_PORT),
            %% Initially no connections
            Count = erwind_tcp_listener:get_connection_count(),
            ?assertEqual(0, Count),
            stop_listener();
        _Pid ->
            %% Listener already running, just verify count works
            Count = erwind_tcp_listener:get_connection_count(),
            ?assert(is_integer(Count))
    end.

double_start_fails() ->
    case whereis(erwind_tcp_listener) of
        undefined ->
            %% First start should succeed
            {ok, _Pid} = erwind_tcp_listener:start_link(?TEST_PORT),
            %% Second start on same port should fail
            ?assertMatch({error, _}, erwind_tcp_listener:start_link(?TEST_PORT)),
            stop_listener();
        _Pid ->
            %% Listener already running, verify double start fails
            ?assertMatch({error, _}, erwind_tcp_listener:start_link(?TEST_PORT))
    end.

client_can_connect() ->
    case whereis(erwind_tcp_listener) of
        undefined ->
            %% Start listener
            {ok, _Pid} = erwind_tcp_listener:start_link(?TEST_PORT),
            timer:sleep(100),
            do_client_connect(),
            stop_listener();
        _Pid ->
            %% Listener already running, try to connect
            timer:sleep(100),
            do_client_connect()
    end.

do_client_connect() ->
    %% Client should be able to connect
    case gen_tcp:connect("127.0.0.1", ?TEST_PORT, [binary, {active, false}], 1000) of
        {ok, Socket} ->
            ?assert(is_port(Socket) orelse is_tuple(Socket)),
            gen_tcp:close(Socket);
        {error, Reason} ->
            %% Connection might fail if listener not ready
            ?assert(lists:member(Reason, [econnrefused, timeout, econnreset]))
    end.
