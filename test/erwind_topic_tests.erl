%% erwind_topic_tests.erl
%% Tests for Topic module

-module(erwind_topic_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("erwind/include/erwind.hrl").

-define(TEST_TOPIC, <<"test_topic">>).
-define(TEST_CHANNEL, <<"test_channel">>).

%% =============================================================================
%% Fixtures
%% =============================================================================

topic_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [
        fun start_stop_test/0,
        fun publish_test/0,
        fun mpub_test/0,
        fun get_channel_test/0,
        fun create_delete_channel_test/0,
        fun list_channels_test/0,
        fun pause_unpause_test/0,
        fun ephemeral_topic_test/0,
        fun get_stats_test/0
     ]}.

setup() ->
    %% Ensure registry is initialized
    erwind_topic_registry:init(),
    %% Start channel supervisor if not running
    case whereis(erwind_channel_sup) of
        undefined ->
            {ok, _} = erwind_channel_sup:start_link();
        _ -> ok
    end,
    ok.

cleanup(_) ->
    %% Clean up any created topics
    catch erwind_topic_registry:delete_topic(?TEST_TOPIC),
    catch erwind_topic_registry:delete_topic(<<"ephemeral_topic#ephemeral">>),
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

start_stop_test() ->
    {ok, Pid} = erwind_topic:start_link(?TEST_TOPIC),
    ?assert(is_pid(Pid)),
    ?assertEqual({ok, Pid}, erwind_topic_registry:lookup_topic(?TEST_TOPIC)),
    ok = erwind_topic:stop(Pid),
    timer:sleep(50),
    ?assertEqual(not_found, erwind_topic_registry:lookup_topic(?TEST_TOPIC)).

publish_test() ->
    {ok, Pid} = erwind_topic:start_link(?TEST_TOPIC),
    %% Publish a message
    ok = erwind_topic:publish(Pid, <<"hello world">>),
    timer:sleep(50),
    ok = erwind_topic:stop(Pid).

mpub_test() ->
    {ok, Pid} = erwind_topic:start_link(?TEST_TOPIC),
    %% Publish multiple messages
    Messages = [<<"msg1">>, <<"msg2">>, <<"msg3">>],
    ok = erwind_topic:mpub(Pid, Messages),
    timer:sleep(50),
    ok = erwind_topic:stop(Pid).

get_channel_test() ->
    {ok, Pid} = erwind_topic:start_link(?TEST_TOPIC),
    %% Get or create a channel
    {ok, ChannelPid} = erwind_topic:get_channel(Pid, ?TEST_CHANNEL),
    ?assert(is_pid(ChannelPid)),
    %% Get the same channel again
    {ok, SameChannelPid} = erwind_topic:get_channel(Pid, ?TEST_CHANNEL),
    ?assertEqual(ChannelPid, SameChannelPid),
    ok = erwind_topic:stop(Pid).

create_delete_channel_test() ->
    {ok, Pid} = erwind_topic:start_link(?TEST_TOPIC),
    %% Create a channel
    {ok, ChannelPid} = erwind_topic:create_channel(Pid, ?TEST_CHANNEL),
    ?assert(is_pid(ChannelPid)),
    %% Delete the channel
    ok = erwind_topic:delete_channel(Pid, ?TEST_CHANNEL),
    timer:sleep(50),
    ok = erwind_topic:stop(Pid).

list_channels_test() ->
    {ok, Pid} = erwind_topic:start_link(?TEST_TOPIC),
    %% Initially no channels
    [] = erwind_topic:list_channels(Pid),
    %% Create some channels
    {ok, _} = erwind_topic:create_channel(Pid, <<"ch1">>),
    {ok, _} = erwind_topic:create_channel(Pid, <<"ch2">>),
    Channels = erwind_topic:list_channels(Pid),
    ?assertEqual(2, length(Channels)),
    ok = erwind_topic:stop(Pid).

pause_unpause_test() ->
    {ok, Pid} = erwind_topic:start_link(?TEST_TOPIC),
    %% Initially not paused
    ?assertEqual(false, erwind_topic:is_paused(Pid)),
    %% Pause the topic
    ok = erwind_topic:pause(Pid),
    ?assertEqual(true, erwind_topic:is_paused(Pid)),
    %% Unpause the topic
    ok = erwind_topic:unpause(Pid),
    ?assertEqual(false, erwind_topic:is_paused(Pid)),
    ok = erwind_topic:stop(Pid).

ephemeral_topic_test() ->
    EphemeralTopic = <<"ephemeral_topic#ephemeral">>,
    {ok, Pid} = erwind_topic:start_link(EphemeralTopic),
    ?assert(erwind_topic:is_ephemeral(EphemeralTopic)),
    ok = erwind_topic:stop(Pid).

get_stats_test() ->
    {ok, Pid} = erwind_topic:start_link(?TEST_TOPIC),
    Stats = erwind_topic:get_stats(Pid),
    ?assertEqual(?TEST_TOPIC, maps:get(name, Stats)),
    ?assertEqual(0, maps:get(message_count, Stats)),
    ?assertEqual(0, maps:get(channel_count, Stats)),
    ?assertEqual(false, maps:get(paused, Stats)),
    ok = erwind_topic:stop(Pid).

%% =============================================================================
%% Internal helper tests
%% =============================================================================

create_message_test() ->
    Body = <<"test message">>,
    Msg = erwind_topic:create_message(Body),
    ?assertEqual(Body, Msg#nsq_message.body),
    ?assertEqual(1, Msg#nsq_message.attempts),
    ?assert(is_binary(Msg#nsq_message.id)),
    ?assert(is_integer(Msg#nsq_message.timestamp)).

is_ephemeral_test() ->
    ?assertEqual(true, erwind_topic:is_ephemeral(<<"topic#ephemeral">>)),
    ?assertEqual(false, erwind_topic:is_ephemeral(<<"normal_topic">>)).
