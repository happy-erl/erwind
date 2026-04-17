%% erwind_channel_sup_tests.erl
%% Tests for Channel supervisor module

-module(erwind_channel_sup_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TEST_TOPIC, <<"test_topic_ch_sup">>).
-define(TEST_CHANNEL, <<"test_channel_ch_sup">>).

%% =============================================================================
%% Fixtures
%% =============================================================================

channel_sup_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [
        fun init_test/0,
        fun start_channel_test/0,
        fun stop_channel_test/0
     ]}.

setup() ->
    %% Start channel supervisor if not running
    case whereis(erwind_channel_sup) of
        undefined ->
            {ok, _} = erwind_channel_sup:start_link();
        _ -> ok
    end,
    ok.

cleanup(_) ->
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

init_test() ->
    {ok, {SupFlags, [ChannelSpec]}} = erwind_channel_sup:init([]),
    ?assertEqual(simple_one_for_one, maps:get(strategy, SupFlags)),
    ?assertEqual(erwind_channel, maps:get(id, ChannelSpec)),
    ?assertEqual(temporary, maps:get(restart, ChannelSpec)).

start_channel_test() ->
    Result = erwind_channel_sup:start_channel(?TEST_TOPIC, ?TEST_CHANNEL),
    ?assertMatch({ok, Pid} when is_pid(Pid), Result),
    {ok, Pid} = Result,
    ok = erwind_channel:stop(Pid).

stop_channel_test() ->
    Result = erwind_channel_sup:start_channel(?TEST_TOPIC, ?TEST_CHANNEL),
    ?assertMatch({ok, Pid} when is_pid(Pid), Result),
    {ok, Pid} = Result,
    ok = erwind_channel_sup:stop_channel(Pid),
    timer:sleep(50).
