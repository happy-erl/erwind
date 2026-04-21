%% erwind_http_sup_tests.erl
%% Tests for HTTP Supervisor module

-module(erwind_http_sup_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Tests
%% =============================================================================

supervisor_init_test() ->
    %% Get child specs without starting
    {ok, {SupFlags, Children}} = erwind_http_sup:init([]),

    %% Verify supervisor flags
    ?assertEqual(one_for_one, maps:get(strategy, SupFlags)),
    ?assertEqual(10, maps:get(intensity, SupFlags)),
    ?assertEqual(60, maps:get(period, SupFlags)),

    %% Verify cowboy child spec
    [CowboyChild] = Children,
    ?assertEqual(cowboy_clear, maps:get(id, CowboyChild)),
    ?assertEqual(permanent, maps:get(restart, CowboyChild)),
    ?assertEqual(worker, maps:get(type, CowboyChild)),
    ok.

routes_compilation_test() ->
    %% Test that routes can be compiled
    Routes = erwind_http_api:routes(),
    true = is_list(Routes),
    Dispatch = cowboy_router:compile([{'_', Routes}]),
    true = is_map(Dispatch) orelse is_list(Dispatch),
    ok.
