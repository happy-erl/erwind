%% erwind_tcp_sup_tests.erl
%% Tests for TCP supervisor module

-module(erwind_tcp_sup_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TEST_PORT, 14153).

%% =============================================================================
%% Unit tests
%% =============================================================================

tcp_sup_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [
        fun sup_strategy/0,
        fun sup_child_specs/0
     ]}.

setup() ->
    ok.

cleanup(_) ->
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

sup_strategy() ->
    %% Get supervisor strategy
    {ok, {SupFlags, _}} = erwind_tcp_sup:init([?TEST_PORT]),
    Strategy = maps:get(strategy, SupFlags),
    ?assertEqual(rest_for_one, Strategy).

sup_child_specs() ->
    %% Check child specs are correct
    {ok, {_SupFlags, Children}} = erwind_tcp_sup:init([?TEST_PORT]),
    %% Should have TCP listener, acceptor pool sup, and connection sup
    Ids = [Id || #{id := Id} <- Children],
    ?assert(lists:member(erwind_tcp_listener, Ids)),
    ?assert(lists:member(erwind_acceptor_pool_sup, Ids)),
    ?assert(lists:member(erwind_connection_sup, Ids)).
