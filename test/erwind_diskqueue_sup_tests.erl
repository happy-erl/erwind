%% erwind_diskqueue_sup_tests.erl
%% 磁盘队列监督者测试

-module(erwind_diskqueue_sup_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Tests
%% =============================================================================

start_link_test() ->
    %% 使用唯一的注册名避免冲突
    Name = list_to_atom("diskqueue_sup_" ++ integer_to_list(erlang:unique_integer())),
    {ok, Pid} = erwind_diskqueue_sup:start_link(),
    ?assert(is_pid(Pid)),
    %% 清理
    catch exit(Pid, normal).

start_queue_test() ->
    {ok, _} = erwind_diskqueue_sup:start_link(),

    Name = iolist_to_binary([<<"queue_">>, integer_to_binary(erlang:unique_integer())]),
    Result = erwind_diskqueue_sup:start_queue(Name),
    ?assertMatch({ok, _}, Result),

    {ok, Pid} = Result,

    %% 重复启动应返回已存在的 PID
    {ok, Pid2} = erwind_diskqueue_sup:start_queue(Name),
    ?assertEqual(Pid, Pid2),

    %% 停止队列
    ok = erwind_diskqueue_sup:stop_queue(Name),

    %% 清理监督者
    catch exit(whereis(erwind_diskqueue_sup), normal).

get_queue_test() ->
    {ok, _} = erwind_diskqueue_sup:start_link(),

    Name = iolist_to_binary([<<"get_queue_">>, integer_to_binary(erlang:unique_integer())]),

    %% 不存在的队列
    ?assertEqual(not_found, erwind_diskqueue_sup:get_queue(Name)),

    %% 启动队列
    {ok, Pid} = erwind_diskqueue_sup:start_queue(Name),
    {ok, RetrievedPid} = erwind_diskqueue_sup:get_queue(Name),
    ?assertEqual(Pid, RetrievedPid),

    ok = erwind_diskqueue_sup:stop_queue(Name),
    catch exit(whereis(erwind_diskqueue_sup), normal).

list_queues_test() ->
    {ok, _} = erwind_diskqueue_sup:start_link(),

    Name1 = iolist_to_binary([<<"list_1_">>, integer_to_binary(erlang:unique_integer())]),
    Name2 = iolist_to_binary([<<"list_2_">>, integer_to_binary(erlang:unique_integer())]),

    {ok, _} = erwind_diskqueue_sup:start_queue(Name1),
    {ok, _} = erwind_diskqueue_sup:start_queue(Name2),

    Queues = erwind_diskqueue_sup:list_queues(),
    ?assert(length(Queues) >= 2),

    ok = erwind_diskqueue_sup:stop_queue(Name1),
    ok = erwind_diskqueue_sup:stop_queue(Name2),
    catch exit(whereis(erwind_diskqueue_sup), normal).

stop_queue_test() ->
    {ok, _} = erwind_diskqueue_sup:start_link(),

    Name = iolist_to_binary([<<"stop_queue_">>, integer_to_binary(erlang:unique_integer())]),
    {ok, _} = erwind_diskqueue_sup:start_queue(Name),

    ok = erwind_diskqueue_sup:stop_queue(Name),
    ?assertEqual(not_found, erwind_diskqueue_sup:get_queue(Name)),

    %% 停止不存在的队列
    ?assertEqual({error, not_found}, erwind_diskqueue_sup:stop_queue(<<"nonexistent">>)),

    catch exit(whereis(erwind_diskqueue_sup), normal).
