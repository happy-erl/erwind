%% erwind_stats_tests.erl
%% Stats 模块单元测试

-module(erwind_stats_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Test Fixtures
%% =============================================================================

stats_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun start_link_test/0,
      fun incr_topic_test/0,
      fun incr_channel_test/0,
      fun get_topic_stats_test/0,
      fun get_channel_stats_test/0,
      fun get_global_stats_test/0]}.

setup() ->
    %% Handle already started case
    case whereis(erwind_stats) of
        undefined ->
            {ok, Pid} = erwind_stats:start_link(),
            [{stats, Pid}];
        Pid when is_pid(Pid) ->
            [{stats, Pid}]
    end.

cleanup(_State) ->
    ok.  %% Don't kill shared stats process

%% =============================================================================
%% Tests
%% =============================================================================

start_link_test() ->
    ?assert(is_pid(whereis(erwind_stats))).

incr_topic_test() ->
    %% Use unique topic name to avoid conflicts
    TopicName = iolist_to_binary([<<"test_topic_">>, integer_to_binary(erlang:unique_integer())]),
    ok = erwind_stats:incr_topic_msg_count(TopicName),
    ok = erwind_stats:incr_topic_msg_count(TopicName),
    ok = erwind_stats:incr_topic_msg_count(TopicName),

    Stats = erwind_stats:get_topic_stats(TopicName),
    ?assertEqual(3, maps:get(message_count, Stats)).

incr_channel_test() ->
    %% Use unique names to avoid conflicts
    UniqueId = erlang:unique_integer(),
    TopicName = iolist_to_binary([<<"channel_topic_">>, integer_to_binary(UniqueId)]),
    ChannelName = iolist_to_binary([<<"test_channel_">>, integer_to_binary(UniqueId)]),
    ok = erwind_stats:incr_channel_msg_count(TopicName, ChannelName),
    ok = erwind_stats:incr_channel_msg_count(TopicName, ChannelName),

    Stats = erwind_stats:get_channel_stats(TopicName, ChannelName),
    ?assertEqual(2, maps:get(message_count, Stats)).

get_topic_stats_test() ->
    Stats = erwind_stats:get_topic_stats(<<"nonexistent_topic_">>),
    ?assertEqual(0, maps:get(message_count, Stats)).

get_channel_stats_test() ->
    Stats = erwind_stats:get_channel_stats(<<"no_topic_">>, <<"no_channel_">>),
    ?assertEqual(0, maps:get(message_count, Stats)).

get_global_stats_test() ->
    %% Just verify the function works
    Stats = erwind_stats:get_global_stats(),
    ?assert(is_map(Stats)),
    ?assert(maps:is_key(total_messages, Stats)).
