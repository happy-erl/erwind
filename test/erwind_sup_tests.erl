%% erwind_sup_tests.erl
%% Tests for root supervisor module

-module(erwind_sup_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Unit tests
%% =============================================================================

sup_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [
        fun sup_strategy/0,
        fun sup_intensity/0,
        fun sup_child_specs/0,
        fun child_restart_types/0,
        fun child_shutdown_timeouts/0,
        fun child_types/0
     ]}.

setup() ->
    %% Stop any existing supervisor tree
    case whereis(erwind_sup) of
        undefined -> ok;
        OldPid ->
            unlink(OldPid),
            exit(OldPid, normal),
            timer:sleep(100)
    end,
    ok.

cleanup(_) ->
    %% Stop the supervisor tree if running
    case whereis(erwind_sup) of
        undefined -> ok;
        Pid ->
            unlink(Pid),
            exit(Pid, normal),
            timer:sleep(100)
    end,
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

sup_strategy() ->
    {ok, {SupFlags, _}} = erwind_sup:init([]),
    Strategy = maps:get(strategy, SupFlags),
    %% one_for_all: 一个子进程崩溃，所有子进程都重启
    %% 这确保了系统的整体一致性
    ?assertEqual(one_for_all, Strategy).

sup_intensity() ->
    {ok, {SupFlags, _}} = erwind_sup:init([]),
    Intensity = maps:get(intensity, SupFlags),
    Period = maps:get(period, SupFlags),
    %% 最大重启次数: 10次/60秒
    ?assertEqual(10, Intensity),
    ?assertEqual(60, Period).

sup_child_specs() ->
    {ok, {_SupFlags, Children}} = erwind_sup:init([]),
    %% 验证所有子进程 ID
    Ids = [Id || #{id := Id} <- Children],
    ?assert(lists:member(erwind_tcp_sup, Ids)),
    ?assert(lists:member(erwind_topic_sup, Ids)),
    ?assert(lists:member(erwind_channel_sup, Ids)),
    ?assert(lists:member(erwind_stats, Ids)),
    ?assert(lists:member(erwind_lookupd, Ids)),
    ?assert(lists:member(erwind_http_sup, Ids)).

child_restart_types() ->
    {ok, {_SupFlags, Children}} = erwind_sup:init([]),
    %% 验证子进程重启策略
    ChildMap = maps:from_list([{Id, Spec} || #{id := Id} = Spec <- Children]),

    %% 监督者应该是 permanent 重启
    ?assertEqual(permanent, maps:get(restart, maps:get(erwind_tcp_sup, ChildMap))),
    ?assertEqual(permanent, maps:get(restart, maps:get(erwind_topic_sup, ChildMap))),
    ?assertEqual(permanent, maps:get(restart, maps:get(erwind_channel_sup, ChildMap))),
    ?assertEqual(permanent, maps:get(restart, maps:get(erwind_http_sup, ChildMap))),

    %% 工作进程也应该是 permanent
    ?assertEqual(permanent, maps:get(restart, maps:get(erwind_stats, ChildMap))),
    ?assertEqual(permanent, maps:get(restart, maps:get(erwind_lookupd, ChildMap))).

child_shutdown_timeouts() ->
    {ok, {_SupFlags, Children}} = erwind_sup:init([]),
    ChildMap = maps:from_list([{Id, Spec} || #{id := Id} = Spec <- Children]),

    %% 监督者应该有 infinity 超时
    ?assertEqual(infinity, maps:get(shutdown, maps:get(erwind_tcp_sup, ChildMap))),
    ?assertEqual(infinity, maps:get(shutdown, maps:get(erwind_topic_sup, ChildMap))),
    ?assertEqual(infinity, maps:get(shutdown, maps:get(erwind_channel_sup, ChildMap))),
    ?assertEqual(infinity, maps:get(shutdown, maps:get(erwind_http_sup, ChildMap))),

    %% 工作进程应该有 5000ms 超时
    ?assertEqual(5000, maps:get(shutdown, maps:get(erwind_stats, ChildMap))),
    ?assertEqual(5000, maps:get(shutdown, maps:get(erwind_lookupd, ChildMap))).

%% =============================================================================
%% Integration tests
%% =============================================================================

%% Note: start_link test is skipped because starting the root supervisor
%% requires all dependencies to be available. Use erwind_integration_tests
%% for full application startup tests.

child_types() ->
    {ok, {_SupFlags, Children}} = erwind_sup:init([]),
    ChildMap = maps:from_list([{Id, Spec} || #{id := Id} = Spec <- Children]),

    %% 验证子进程类型
    ?assertEqual(supervisor, maps:get(type, maps:get(erwind_tcp_sup, ChildMap))),
    ?assertEqual(supervisor, maps:get(type, maps:get(erwind_topic_sup, ChildMap))),
    ?assertEqual(supervisor, maps:get(type, maps:get(erwind_channel_sup, ChildMap))),
    ?assertEqual(supervisor, maps:get(type, maps:get(erwind_http_sup, ChildMap))),
    ?assertEqual(worker, maps:get(type, maps:get(erwind_stats, ChildMap))),
    ?assertEqual(worker, maps:get(type, maps:get(erwind_lookupd, ChildMap))).
