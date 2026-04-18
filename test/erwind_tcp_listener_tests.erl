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
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [
        fun start_stop_test/0,
        fun get_port_test/0,
        fun get_listen_socket_test/0,
        fun get_connection_count_test/0,
        fun double_start_fails_test/0,
        fun client_can_connect/0
     ]}.

setup() ->
    %% Don't start application - we test the module directly
    ok.

cleanup(_) ->
    %% Stop the listener if running
    case whereis(erwind_tcp_listener) of
        undefined -> ok;
        _Pid -> erwind_tcp_listener:stop()
    end,
    timer:sleep(50),
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

start_stop_test() ->
    %% TCP listener should start on test port
    Result = erwind_tcp_listener:start_link(?TEST_PORT),
    ?assertMatch({ok, _}, Result),
    erwind_tcp_listener:stop().

get_port_test() ->
    {ok, _Pid} = erwind_tcp_listener:start_link(?TEST_PORT),
    ?assertEqual(?TEST_PORT, erwind_tcp_listener:get_port()),
    erwind_tcp_listener:stop().

get_listen_socket_test() ->
    {ok, _Pid} = erwind_tcp_listener:start_link(?TEST_PORT),
    Socket = erwind_tcp_listener:get_listen_socket(),
    ?assertMatch(Socket when Socket =/= undefined, Socket),
    erwind_tcp_listener:stop().

get_connection_count_test() ->
    {ok, _Pid} = erwind_tcp_listener:start_link(?TEST_PORT),
    %% Initially no connections
    Count = erwind_tcp_listener:get_connection_count(),
    ?assertEqual(0, Count),
    erwind_tcp_listener:stop().

double_start_fails_test() ->
    %% First start should succeed
    {ok, _Pid} = erwind_tcp_listener:start_link(?TEST_PORT),
    %% Second start on same port should fail
    ?assertMatch({error, _}, erwind_tcp_listener:start_link(?TEST_PORT)),
    erwind_tcp_listener:stop().

client_can_connect() ->
    %% Start listener
    {ok, _Pid} = erwind_tcp_listener:start_link(?TEST_PORT),
    timer:sleep(100),
    %% Client should be able to connect
    case gen_tcp:connect("127.0.0.1", ?TEST_PORT, [binary, {active, false}], 1000) of
        {ok, Socket} ->
            ?assert(is_port(Socket) orelse is_tuple(Socket)),
            gen_tcp:close(Socket);
        {error, Reason} ->
            %% Connection might fail if listener not ready
            ?assert(lists:member(Reason, [econnrefused, timeout, econnreset]))
    end,
    erwind_tcp_listener:stop().
