%% erwind_inflight_tracker_tests.erl
%% 在途消息跟踪模块测试

-module(erwind_inflight_tracker_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("erwind/include/erwind.hrl").

%% =============================================================================
%% Test Fixtures
%% =============================================================================

inflight_tracker_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun start_link_test/0,
      fun track_ack_test/0,
      fun requeue_test/0,
      fun touch_test/0,
      fun count_test/0]}.

setup() ->
    {ok, Pid} = erwind_inflight_tracker:start_link(<<"test_topic">>, <<"test_channel">>),
    [{tracker, Pid}].

cleanup(State) ->
    Pid = proplists:get_value(tracker, State),
    case Pid of
        undefined -> ok;
        _ when is_pid(Pid) -> gen_server:stop(Pid)
    end.

%% =============================================================================
%% Tests
%% =============================================================================

start_link_test() ->
    {ok, Pid} = erwind_inflight_tracker:start_link(<<"topic">>, <<"channel">>),
    ?assert(is_pid(Pid)),
    gen_server:stop(Pid).

track_ack_test() ->
    {ok, Pid} = erwind_inflight_tracker:start_link(<<"topic">>, <<"channel">>),

    MsgId = <<"msg1234567890ab">>,
    Msg = #nsq_message{id = MsgId, timestamp = 1, attempts = 1, body = <<"test">>},
    ConsumerPid = spawn(fun() -> timer:sleep(1000) end),

    %% Track message
    erwind_inflight_tracker:track(Pid, MsgId, Msg, ConsumerPid, 60000),
    ?assertEqual(1, erwind_inflight_tracker:count(Pid)),

    %% Get message
    {ok, _Entry} = erwind_inflight_tracker:get(Pid, MsgId),
    %% Entry exists, verify count

    %% Ack message
    ok = erwind_inflight_tracker:ack(Pid, MsgId),
    ?assertEqual(0, erwind_inflight_tracker:count(Pid)),

    %% Ack again should fail
    ?assertEqual({error, not_found}, erwind_inflight_tracker:ack(Pid, MsgId)),

    ConsumerPid ! kill,
    gen_server:stop(Pid).

requeue_test() ->
    {ok, Pid} = erwind_inflight_tracker:start_link(<<"topic">>, <<"channel">>),

    MsgId = <<"msg1234567890ab">>,
    Msg = #nsq_message{id = MsgId, timestamp = 1, attempts = 1, body = <<"test">>},
    ConsumerPid = spawn(fun() -> timer:sleep(1000) end),

    erwind_inflight_tracker:track(Pid, MsgId, Msg, ConsumerPid, 60000),

    %% Requeue should return the message
    {ok, RetrievedMsg} = erwind_inflight_tracker:requeue(Pid, MsgId),
    ?assertEqual(Msg, RetrievedMsg),
    ?assertEqual(0, erwind_inflight_tracker:count(Pid)),

    ConsumerPid ! kill,
    gen_server:stop(Pid).

touch_test() ->
    {ok, Pid} = erwind_inflight_tracker:start_link(<<"topic">>, <<"channel">>),

    MsgId = <<"msg1234567890ab">>,
    Msg = #nsq_message{id = MsgId, timestamp = 1, attempts = 1, body = <<"test">>},
    ConsumerPid = spawn(fun() -> timer:sleep(1000) end),

    erwind_inflight_tracker:track(Pid, MsgId, Msg, ConsumerPid, 60000),

    %% Touch should update the expire time
    ok = erwind_inflight_tracker:touch(Pid, MsgId),

    %% Touch non-existent should fail
    ?assertEqual({error, not_found}, erwind_inflight_tracker:touch(Pid, <<"nonexistent">>)),

    erwind_inflight_tracker:ack(Pid, MsgId),
    ConsumerPid ! kill,
    gen_server:stop(Pid).

count_test() ->
    {ok, Pid} = erwind_inflight_tracker:start_link(<<"topic">>, <<"channel">>),

    ?assertEqual(0, erwind_inflight_tracker:count(Pid)),

    Msg1 = #nsq_message{id = <<"msg000000000001">>, timestamp = 1, attempts = 1, body = <<>>},
    Msg2 = #nsq_message{id = <<"msg000000000002">>, timestamp = 2, attempts = 1, body = <<>>},
    ConsumerPid = spawn(fun() -> timer:sleep(1000) end),

    erwind_inflight_tracker:track(Pid, <<"msg000000000001">>, Msg1, ConsumerPid, 60000),
    erwind_inflight_tracker:track(Pid, <<"msg000000000002">>, Msg2, ConsumerPid, 60000),

    ?assertEqual(2, erwind_inflight_tracker:count(Pid)),

    erwind_inflight_tracker:ack(Pid, <<"msg000000000001">>),
    ?assertEqual(1, erwind_inflight_tracker:count(Pid)),

    ConsumerPid ! kill,
    gen_server:stop(Pid).

get_all_test() ->
    {ok, Pid} = erwind_inflight_tracker:start_link(<<"topic">>, <<"channel">>),

    Msg1 = #nsq_message{id = <<"msg000000000001">>, timestamp = 1, attempts = 1, body = <<>>},
    ConsumerPid = spawn(fun() -> timer:sleep(1000) end),

    erwind_inflight_tracker:track(Pid, <<"msg000000000001">>, Msg1, ConsumerPid, 60000),

    All = erwind_inflight_tracker:get_all(Pid),
    ?assertEqual(1, length(All)),

    ConsumerPid ! kill,
    gen_server:stop(Pid).
