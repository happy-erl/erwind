%% erwind_http_api_tests.erl
%% Tests for HTTP API module

-module(erwind_http_api_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Tests
%% =============================================================================

routes_test() ->
    Routes = erwind_http_api:routes(),
    ?assert(is_list(Routes)),
    ?assert(length(Routes) >= 10),

    %% Check required routes exist (paths are strings, not binaries)
    Paths = [P || {P, _, _} <- Routes],
    ?assert(lists:member("/ping", Paths)),
    ?assert(lists:member("/info", Paths)),
    ?assert(lists:member("/stats", Paths)),
    ?assert(lists:member("/topic/create", Paths)),
    ?assert(lists:member("/topic/delete", Paths)),
    ?assert(lists:member("/topic/list", Paths)),
    ?assert(lists:member("/channel/create", Paths)),
    ?assert(lists:member("/channel/delete", Paths)),
    ?assert(lists:member("/pub", Paths)),
    ?assert(lists:member("/mpub", Paths)),
    ?assert(lists:member("/dpub", Paths)),
    ok.

handler_test() ->
    Routes = erwind_http_api:routes(),
    %% Each route should have path, module, and state with handler
    lists:foreach(fun({Path, Module, State}) ->
        ?assert(is_binary(Path) orelse is_list(Path), {invalid_path, Path}),
        ?assertEqual(erwind_http_api, Module, {invalid_module, Module}),
        ?assert(is_map(State), {invalid_state, State}),
        ?assert(maps:is_key(handler, State), {missing_handler, State})
    end, Routes),
    ok.

http_methods_test() ->
    %% Verify all handlers are defined
    Handlers = [ping, info, stats, topic_create, topic_delete, topic_empty,
                topic_pause, topic_unpause, topic_list, channel_create,
                channel_delete, channel_empty, channel_pause, channel_unpause,
                pub, mpub, dpub],
    Routes = erwind_http_api:routes(),
    RouteHandlers = [maps:get(handler, State) || {_, _, State} <- Routes],
    lists:foreach(fun(Handler) ->
        ?assert(lists:member(Handler, RouteHandlers), {missing_handler, Handler})
    end, Handlers),
    ok.
