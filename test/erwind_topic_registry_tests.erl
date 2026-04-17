%% erwind_topic_registry_tests.erl
%% Tests for Topic registry module

-module(erwind_topic_registry_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TEST_TOPIC, <<"test_registry_topic">>).

%% =============================================================================
%% Fixtures
%% =============================================================================

registry_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [
        fun init_test/0,
        fun register_lookup_test/0,
        fun unregister_test/0,
        fun list_topics_test/0
     ]}.

setup() ->
    erwind_topic_registry:init(),
    ok.

cleanup(_) ->
    catch erwind_topic_registry:delete_topic(?TEST_TOPIC),
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

init_test() ->
    %% Registry should be initialized by setup
    Topics = erwind_topic_registry:list_topics(),
    ?assert(is_list(Topics)).

register_lookup_test() ->
    Pid = self(),
    %% Register a topic
    true = erwind_topic_registry:register_topic(?TEST_TOPIC, Pid),
    %% Lookup should return the pid
    ?assertEqual({ok, Pid}, erwind_topic_registry:lookup_topic(?TEST_TOPIC)).

unregister_test() ->
    Pid = self(),
    %% Register then unregister
    true = erwind_topic_registry:register_topic(?TEST_TOPIC, Pid),
    ?assertEqual({ok, Pid}, erwind_topic_registry:lookup_topic(?TEST_TOPIC)),
    true = erwind_topic_registry:unregister_topic(?TEST_TOPIC),
    ?assertEqual(not_found, erwind_topic_registry:lookup_topic(?TEST_TOPIC)).

list_topics_test() ->
    Pid = self(),
    %% Register multiple topics
    true = erwind_topic_registry:register_topic(<<"topic1">>, Pid),
    true = erwind_topic_registry:register_topic(<<"topic2">>, Pid),
    Topics = erwind_topic_registry:list_topics(),
    ?assertEqual(2, length(Topics)),
    ?assert(lists:member({<<"topic1">>, Pid}, Topics)),
    ?assert(lists:member({<<"topic2">>, Pid}, Topics)).
