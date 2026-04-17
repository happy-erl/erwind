%% erwind_channel_tests.erl
%% Tests for Channel module

-module(erwind_channel_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("../include/erwind.hrl").

-define(TEST_TOPIC, <<"test_topic_ch">>).
-define(TEST_CHANNEL, <<"test_channel_ch">>).

%% =============================================================================
%% Fixtures
%% =============================================================================

channel_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [
        fun start_stop_test/0,
        fun put_message_test/0,
        fun subscribe_unsubscribe_test/0,
        fun finish_message_test/0,
        fun update_rdy_test/0,
        fun get_stats_test/0,
        fun ephemeral_channel_test/0
     ]}.

setup() ->
    ok.

cleanup(_) ->
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

start_stop_test() ->
    {ok, Pid} = erwind_channel:start_link(?TEST_TOPIC, ?TEST_CHANNEL),
    ?assert(is_pid(Pid)),
    ok = erwind_channel:stop(Pid).

put_message_test() ->
    {ok, Pid} = erwind_channel:start_link(?TEST_TOPIC, ?TEST_CHANNEL),
    Msg = #nsq_message{
        id = erwind_protocol:generate_msg_id(),
        timestamp = erlang:system_time(millisecond),
        attempts = 1,
        body = <<"test message">>
    },
    ok = erwind_channel:put_message(Pid, Msg),
    ok = erwind_channel:stop(Pid).

subscribe_unsubscribe_test() ->
    {ok, Pid} = erwind_channel:start_link(?TEST_TOPIC, ?TEST_CHANNEL),
    ConsumerPid = self(),
    %% Subscribe
    ok = erwind_channel:subscribe(Pid, ConsumerPid),
    [ConsumerPid] = erwind_channel:get_consumers(Pid),
    %% Subscribe again should fail
    {error, already_subscribed} = erwind_channel:subscribe(Pid, ConsumerPid),
    %% Unsubscribe
    ok = erwind_channel:unsubscribe(Pid, ConsumerPid),
    [] = erwind_channel:get_consumers(Pid),
    ok = erwind_channel:stop(Pid).

finish_message_test() ->
    {ok, Pid} = erwind_channel:start_link(?TEST_TOPIC, ?TEST_CHANNEL),
    MsgId = erwind_protocol:generate_msg_id(),
    ok = erwind_channel:finish_message(Pid, MsgId),
    ok = erwind_channel:stop(Pid).

update_rdy_test() ->
    {ok, Pid} = erwind_channel:start_link(?TEST_TOPIC, ?TEST_CHANNEL),
    ConsumerPid = self(),
    ok = erwind_channel:subscribe(Pid, ConsumerPid),
    ok = erwind_channel:update_rdy(Pid, 100),
    ok = erwind_channel:stop(Pid).

get_stats_test() ->
    {ok, Pid} = erwind_channel:start_link(?TEST_TOPIC, ?TEST_CHANNEL),
    Stats = erwind_channel:get_stats(Pid),
    ?assertEqual(?TEST_TOPIC, maps:get(topic, Stats)),
    ?assertEqual(?TEST_CHANNEL, maps:get(channel, Stats)),
    ?assertEqual(0, maps:get(consumer_count, Stats)),
    ok = erwind_channel:stop(Pid).

ephemeral_channel_test() ->
    EphemeralChannel = <<"ephemeral_ch#ephemeral">>,
    {ok, Pid} = erwind_channel:start_link(?TEST_TOPIC, EphemeralChannel),
    Stats = erwind_channel:get_stats(Pid),
    ?assertEqual(true, maps:get(ephemeral, Stats)),
    ok = erwind_channel:stop(Pid).
