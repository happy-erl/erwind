%% erwind_config_tests.erl
%% 配置管理模块测试

-module(erwind_config_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% 基本配置操作测试
%% =============================================================================

get_test() ->
    %% 先设置一个测试值
    application:set_env(erwind, test_key, test_value),

    %% 测试获取配置
    ?assertEqual({ok, test_value}, erwind_config:get(test_key)),

    %% 测试获取不存在的配置
    ?assertEqual(undefined, erwind_config:get(non_existent_key)).

get_with_default_test() ->
    %% 测试获取带默认值的配置
    ?assertEqual(default_value, erwind_config:get(non_existent_key, default_value)),

    %% 设置值后获取
    application:set_env(erwind, another_key, actual_value),
    ?assertEqual(actual_value, erwind_config:get(another_key, default_value)).

set_test() ->
    %% 测试设置配置
    ?assertEqual(ok, erwind_config:set(new_key, new_value)),
    ?assertEqual({ok, new_value}, application:get_env(erwind, new_key)).

update_test() ->
    %% 先设置初始值
    application:set_env(erwind, update_test_key, initial_value),

    %% 测试更新配置
    ?assertEqual(ok, erwind_config:update(update_test_key, updated_value)),
    ?assertEqual({ok, updated_value}, application:get_env(erwind, update_test_key)).

%% =============================================================================
%% 配置变更通知测试
%% =============================================================================

notify_change_test() ->
    %% 测试各种配置变更通知
    ?assertEqual(ok, erwind_config:notify_change(log_level, {info, debug})),
    ?assertEqual(ok, erwind_config:notify_change(tcp_port, {4150, 4152})),
    ?assertEqual(ok, erwind_config:notify_change(http_port, {4151, 4153})),
    ?assertEqual(ok, erwind_config:notify_change(max_msg_size, {1048576, 2097152})),
    ?assertEqual(ok, erwind_config:notify_change(stats_enabled, {false, true})),
    ?assertEqual(ok, erwind_config:notify_change(unknown_key, {old, new})).

%% =============================================================================
%% 配置文件重载测试
%% =============================================================================

reload_with_no_config_test() ->
    %% 测试无配置文件时的重载
    Result = erwind_config:reload(),
    %% 由于没有配置文件，应该返回错误（可能是 config_file_not_found 或 consult_failed）
    %% 或者如果找到了配置文件，应该返回 ok
    ?assert(Result =:= ok orelse element(1, Result) =:= error),
    ok.

%% =============================================================================
%% 集成测试
%% =============================================================================

config_workflow_test_() ->
    {setup,
     fun() ->
         %% 保存原始值
         Original = application:get_env(erwind, workflow_test_key),
         Original
     end,
     fun(Original) ->
         %% 恢复原始值
         case Original of
             {ok, Val} -> application:set_env(erwind, workflow_test_key, Val);
             undefined -> application:unset_env(erwind, workflow_test_key)
         end,
         ok
     end,
     fun() ->
         %% 测试完整配置工作流

         %% 1. 设置初始值
         ok = erwind_config:set(workflow_test_key, stage1),
         ?assertEqual({ok, stage1}, erwind_config:get(workflow_test_key)),

         %% 2. 更新值
         ok = erwind_config:update(workflow_test_key, stage2),
         ?assertEqual({ok, stage2}, erwind_config:get(workflow_test_key)),

         %% 3. 带默认值获取
         ?assertEqual(stage2, erwind_config:get(workflow_test_key, default)),

         %% 4. 获取不存在但带默认值
         ?assertEqual(fallback, erwind_config:get(nonexistent_workflow_key, fallback))
     end}.
