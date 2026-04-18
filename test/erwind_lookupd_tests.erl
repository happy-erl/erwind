%% erwind_lookupd_tests.erl
%% Lookupd 客户端模块单元测试

-module(erwind_lookupd_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Test Fixtures
%% =============================================================================

lookupd_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun start_link_test/0,
      fun register_topic_test/0,
      fun register_channel_test/0,
      fun lookup_test/0]}.

setup() ->
    %% Handle already started case
    case whereis(erwind_lookupd) of
        undefined ->
            {ok, Pid} = erwind_lookupd:start_link(),
            [{lookupd, Pid}];
        Pid when is_pid(Pid) ->
            [{lookupd, Pid}]
    end.

cleanup(_State) ->
    ok.  %% Don't kill shared lookupd process

%% =============================================================================
%% Tests
%% =============================================================================

start_link_test() ->
    ?assert(is_pid(whereis(erwind_lookupd))).

register_topic_test() ->
    %% Use unique topic name
    TopicName = iolist_to_binary([<<"register_topic_">>, integer_to_binary(erlang:unique_integer())]),
    ok = erwind_lookupd:register_topic(TopicName),

    %% Lookup should find it
    {ok, Results} = erwind_lookupd:lookup(TopicName),
    ?assert(length(Results) >= 1),

    %% Unregister
    ok = erwind_lookupd:unregister_topic(TopicName),
    {ok, Results2} = erwind_lookupd:lookup(TopicName),
    ?assertEqual(0, length(Results2)).

register_channel_test() ->
    %% Use unique names
    UniqueId = erlang:unique_integer(),
    TopicName = iolist_to_binary([<<"ch_topic_">>, integer_to_binary(UniqueId)]),
    ChannelName = iolist_to_binary([<<"ch_name_">>, integer_to_binary(UniqueId)]),

    ok = erwind_lookupd:register_channel(TopicName, ChannelName),

    %% Unregister
    ok = erwind_lookupd:unregister_channel(TopicName, ChannelName).

lookup_test() ->
    %% Lookup nonexistent topic
    {ok, Results} = erwind_lookupd:lookup(<<"nonexistent_topic_">>),
    ?assertEqual(0, length(Results)),

    %% Register and lookup with unique name
    TopicName = iolist_to_binary([<<"lookup_topic_">>, integer_to_binary(erlang:unique_integer())]),
    ok = erwind_lookupd:register_topic(TopicName),
    {ok, Results2} = erwind_lookupd:lookup(TopicName),
    ?assert(length(Results2) >= 1),

    %% Verify result structure
    [Result | _] = Results2,
    ?assert(maps:is_key(hostname, Result)),
    ?assert(maps:is_key(tcp_port, Result)),

    ok = erwind_lookupd:unregister_topic(TopicName).
