%% erwind_connection_sup_tests.erl
%% Tests for Connection supervisor module

-module(erwind_connection_sup_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Tests
%% =============================================================================

connection_sup_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [
        fun sup_is_simple_one_for_one/0,
        fun sup_connection_spec/0
     ]}.

setup() ->
    ok.

cleanup(_) ->
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

sup_is_simple_one_for_one() ->
    {ok, {SupFlags, _}} = erwind_connection_sup:init([]),
    Strategy = maps:get(strategy, SupFlags),
    ?assertEqual(simple_one_for_one, Strategy).

sup_connection_spec() ->
    {ok, {_SupFlags, [ChildSpec]}} = erwind_connection_sup:init([]),
    ?assertEqual(erwind_connection, maps:get(id, ChildSpec)),
    ?assertEqual(worker, maps:get(type, ChildSpec)),
    ?assertEqual(temporary, maps:get(restart, ChildSpec)).
