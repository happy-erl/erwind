%% erwind_delayed_queue_tests.erl
%% 延迟队列模块测试

-module(erwind_delayed_queue_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("erwind/include/erwind.hrl").

%% =============================================================================
%% Test Fixtures
%% =============================================================================

delayed_queue_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun start_link_test/0,
      fun schedule_test/0,
      fun cancel_test/0,
      fun count_test/0]}.

setup() ->
    {ok, Pid} = erwind_delayed_queue:start_link(<<"test_topic">>, <<"test_channel">>),
    [{queue, Pid}].

cleanup(State) ->
    Pid = proplists:get_value(queue, State),
    case Pid of
        undefined -> ok;
        _ when is_pid(Pid) -> gen_server:stop(Pid)
    end.

%% =============================================================================
%% Tests
%% =============================================================================

start_link_test() ->
    {ok, Pid} = erwind_delayed_queue:start_link(<<"topic">>, <<"channel">>),
    ?assert(is_pid(Pid)),
    ?assertEqual(0, erwind_delayed_queue:count(Pid)),
    gen_server:stop(Pid).

schedule_test() ->
    {ok, Pid} = erwind_delayed_queue:start_link(<<"topic">>, <<"channel">>),

    Msg = #nsq_message{
        id = <<"msg1234567890ab">>,
        timestamp = erlang:system_time(millisecond),
        attempts = 1,
        body = <<"delayed">>
    },

    {ok, _TimerRef} = erwind_delayed_queue:schedule(Pid, Msg, 1000),
    ?assertEqual(1, erwind_delayed_queue:count(Pid)),

    %% Wait for fire
    timer:sleep(1100),
    ?assertEqual(0, erwind_delayed_queue:count(Pid)),

    gen_server:stop(Pid).

cancel_test() ->
    {ok, Pid} = erwind_delayed_queue:start_link(<<"topic">>, <<"channel">>),

    Msg = #nsq_message{
        id = <<"msg1234567890ab">>,
        timestamp = erlang:system_time(millisecond),
        attempts = 1,
        body = <<"delayed">>
    },

    {ok, _TimerRef} = erwind_delayed_queue:schedule(Pid, Msg, 5000),
    ?assertEqual(1, erwind_delayed_queue:count(Pid)),

    %% Cancel
    ok = erwind_delayed_queue:cancel(Pid, <<"msg1234567890ab">>),
    ?assertEqual(0, erwind_delayed_queue:count(Pid)),

    %% Cancel non-existent
    ?assertEqual({error, not_found}, erwind_delayed_queue:cancel(Pid, <<"nonexistent">>)),

    gen_server:stop(Pid).

count_test() ->
    {ok, Pid} = erwind_delayed_queue:start_link(<<"topic">>, <<"channel">>),

    ?assertEqual(0, erwind_delayed_queue:count(Pid)),

    Msg1 = #nsq_message{id = <<"msg000000000001">>, timestamp = 1, attempts = 1, body = <<>>},
    Msg2 = #nsq_message{id = <<"msg000000000002">>, timestamp = 2, attempts = 1, body = <<>>},

    {ok, _} = erwind_delayed_queue:schedule(Pid, Msg1, 10000),
    {ok, _} = erwind_delayed_queue:schedule(Pid, Msg2, 10000),

    ?assertEqual(2, erwind_delayed_queue:count(Pid)),

    erwind_delayed_queue:cancel(Pid, <<"msg000000000001">>),
    ?assertEqual(1, erwind_delayed_queue:count(Pid)),

    erwind_delayed_queue:cancel(Pid, <<"msg000000000002">>),
    gen_server:stop(Pid).

tick_test() ->
    {ok, Pid} = erwind_delayed_queue:start_link(<<"topic">>, <<"channel">>),

    %% Tick is a no-op for now
    ok = erwind_delayed_queue:tick(Pid),

    gen_server:stop(Pid).
