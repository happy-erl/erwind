%% erwind_acceptor_pool_sup_tests.erl
%% Tests for Acceptor pool supervisor module

-module(erwind_acceptor_pool_sup_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Tests
%% =============================================================================

acceptor_pool_sup_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [
        fun sup_strategy_is_one_for_one/0,
        fun sup_acceptor_specs/0
     ]}.

setup() ->
    ok.

cleanup(_) ->
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

sup_strategy_is_one_for_one() ->
    {ok, {SupFlags, _}} = erwind_acceptor_pool_sup:init([]),
    Strategy = maps:get(strategy, SupFlags),
    ?assertEqual(one_for_one, Strategy).

sup_acceptor_specs() ->
    {ok, {_SupFlags, Children}} = erwind_acceptor_pool_sup:init([]),
    %% Should have acceptor specs for each pool size
    ?assert(length(Children) >= 1),
    %% All should be worker type
    lists:foreach(fun(#{type := Type}) ->
        ?assertEqual(worker, Type)
    end, Children).
