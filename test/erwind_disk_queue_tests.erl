%% erwind_disk_queue_tests.erl
%% 磁盘队列模块测试 - 基础功能测试

-module(erwind_disk_queue_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Tests
%% =============================================================================

%% 测试启动和停止
start_stop_test() ->
    Name = unique_name(),
    DataPath = unique_data_path(),
    application:set_env(erwind, data_path, DataPath),

    {ok, Pid} = erwind_disk_queue:start_link(Name),
    ?assert(is_pid(Pid)),
    ?assertEqual(0, erwind_disk_queue:depth(Pid)),

    ok = erwind_disk_queue:stop(Pid),
    timer:sleep(50),
    catch file:del_dir_r(DataPath).

%% 测试消息写入和读取
single_message_test() ->
    Name = unique_name(),
    DataPath = unique_data_path(),
    application:set_env(erwind, data_path, DataPath),

    {ok, Pid} = erwind_disk_queue:start_link(Name),

    %% 写入消息
    ok = erwind_disk_queue:put(Pid, <<"test">>),

    %% 刷新确保写入
    ok = erwind_disk_queue:flush(Pid),
    timer:sleep(100),

    %% 验证深度增加
    Depth = erwind_disk_queue:depth(Pid),
    ?assert(Depth >= 1),

    ok = erwind_disk_queue:stop(Pid),
    timer:sleep(50),
    catch file:del_dir_r(DataPath).

%% 测试批量写入
batch_write_test() ->
    Name = unique_name(),
    DataPath = unique_data_path(),
    application:set_env(erwind, data_path, DataPath),

    {ok, Pid} = erwind_disk_queue:start_link(Name),

    %% 批量写入
    ok = erwind_disk_queue:put_batch(Pid, [<<"a">>, <<"b">>]),

    %% 刷新确保写入
    ok = erwind_disk_queue:flush(Pid),
    timer:sleep(100),

    %% 验证深度
    Depth = erwind_disk_queue:depth(Pid),
    ?assert(Depth >= 2),

    ok = erwind_disk_queue:stop(Pid),
    timer:sleep(50),
    catch file:del_dir_r(DataPath).

%% 测试空队列
empty_queue_test() ->
    Name = unique_name(),
    DataPath = unique_data_path(),
    application:set_env(erwind, data_path, DataPath),

    {ok, Pid} = erwind_disk_queue:start_link(Name),

    %% 空队列深度应为0
    ?assertEqual(0, erwind_disk_queue:depth(Pid)),

    ok = erwind_disk_queue:stop(Pid),
    timer:sleep(50),
    catch file:del_dir_r(DataPath).

%% =============================================================================
%% Helper functions
%% =============================================================================

unique_name() ->
    iolist_to_binary([<<"test_queue_">>, integer_to_binary(erlang:unique_integer())]).

unique_data_path() ->
    filename:join(["/tmp/erwind_test", integer_to_list(erlang:unique_integer())]).
