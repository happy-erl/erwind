%% erwind_topic_sup_tests.erl
%% Tests for Topic supervisor module

-module(erwind_topic_sup_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TEST_TOPIC, <<"test_topic_sup">>).

%% =============================================================================
%% Fixtures
%% =============================================================================

topic_sup_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [
        fun init_creates_registry/0,
        fun start_topic_test/0,
        fun get_or_create_topic_test/0,
        fun delete_topic_test/0
     ]}.

setup() ->
    %% Ensure registry is initialized
    erwind_topic_registry:init(),
    %% Start topic supervisor if not running
    case whereis(erwind_topic_sup) of
        undefined ->
            {ok, _} = erwind_topic_sup:start_link();
        _ -> ok
    end,
    ok.

cleanup(_) ->
    catch erwind_topic_registry:delete_topic(?TEST_TOPIC),
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

init_creates_registry() ->
    {ok, {SupFlags, [TopicSpec]}} = erwind_topic_sup:init([]),
    ?assertEqual(simple_one_for_one, maps:get(strategy, SupFlags)),
    ?assertEqual(erwind_topic, maps:get(id, TopicSpec)),
    ?assertEqual(temporary, maps:get(restart, TopicSpec)).

start_topic_test() ->
    Result = erwind_topic_sup:start_topic(?TEST_TOPIC),
    ?assertMatch({ok, Pid} when is_pid(Pid), Result),
    {ok, Pid} = Result,
    %% Clean up
    ok = erwind_topic:stop(Pid).

get_or_create_topic_test() ->
    %% First call should create
    {ok, Pid1} = erwind_topic_sup:get_or_create_topic(?TEST_TOPIC),
    ?assert(is_pid(Pid1)),
    %% Second call should return same topic
    {ok, Pid2} = erwind_topic_sup:get_or_create_topic(?TEST_TOPIC),
    ?assertEqual(Pid1, Pid2),
    %% Clean up
    ok = erwind_topic:stop(Pid1).

delete_topic_test() ->
    {ok, Pid} = erwind_topic_sup:start_topic(?TEST_TOPIC),
    ?assertEqual({ok, Pid}, erwind_topic_registry:lookup_topic(?TEST_TOPIC)),
    %% Delete the topic
    ok = erwind_topic_sup:delete_topic(?TEST_TOPIC),
    timer:sleep(50),
    ?assertEqual(not_found, erwind_topic_registry:lookup_topic(?TEST_TOPIC)).
