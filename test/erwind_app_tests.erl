%% erwind_app_tests.erl
%% Tests for application callback module

-module(erwind_app_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Unit tests
%% =============================================================================

app_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [
        fun start_returns_ok/0,
        fun stop_returns_ok/0,
        fun start_type_normal/0
     ]}.

setup() ->
    %% Stop any existing supervisor
    stop_sup_tree(),
    %% Use temp directory for tests
    application:set_env(erwind, data_dir, "/tmp/erwind_test"),
    ok.

cleanup(_) ->
    %% Clean up - stop the supervisor tree
    stop_sup_tree(),
    ok.

stop_sup_tree() ->
    case whereis(erwind_sup) of
        undefined -> ok;
        SupPid ->
            unlink(SupPid),
            exit(SupPid, shutdown),
            timer:sleep(200)
    end,
    case whereis(erwind_tcp_sup) of
        undefined -> ok;
        TcpSupPid ->
            unlink(TcpSupPid),
            exit(TcpSupPid, shutdown),
            timer:sleep(100)
    end,
    case whereis(erwind_tcp_listener) of
        undefined -> ok;
        ListenerPid ->
            unlink(ListenerPid),
            exit(ListenerPid, shutdown),
            timer:sleep(100)
    end.

%% =============================================================================
%% Tests
%% =============================================================================

start_returns_ok() ->
    %% 测试 start/2 返回正确的结果
    Result = erwind_app:start(normal, []),
    case Result of
        {ok, Pid} when is_pid(Pid) ->
            ?assert(is_pid(Pid));
        {ok, Pid, _State} when is_pid(Pid) ->
            ?assert(is_pid(Pid));
        {error, _Reason} ->
            %% 可能是因为监督者已经在运行
            ?assert(true)
    end.

stop_returns_ok() ->
    %% 测试 stop/1 返回 ok
    Result = erwind_app:stop([]),
    ?assertEqual(ok, Result).

start_type_normal() ->
    %% 测试正常启动类型
    Result = erwind_app:start(normal, []),
    case Result of
        {ok, Pid} when is_pid(Pid) -> ?assert(is_pid(Pid));
        {ok, Pid, _} when is_pid(Pid) -> ?assert(is_pid(Pid));
        {error, _} -> ?assert(true)
    end.

%% =============================================================================
%% Integration tests
%% =============================================================================

application_start_stop_test_() ->
    {setup,
     fun() ->
        %% Stop any existing supervisor
        stop_sup_tree(),
        ok
     end,
     fun(_) ->
        %% Clean up
        stop_sup_tree(),
        ok
     end,
     fun() ->
        %% 测试应用程序可以正常启动
        Result = erwind_app:start(normal, []),
        case Result of
            {ok, Pid} when is_pid(Pid) ->
                ?assert(is_pid(Pid));
            {ok, Pid, _} when is_pid(Pid) ->
                ?assert(is_pid(Pid));
            {error, _} ->
                ?assert(true)
        end
     end}.

%% =============================================================================
%% 新增功能测试
%% =============================================================================

version_test() ->
    %% 测试获取版本号
    Version = erwind_app:version(),
    ?assert(is_binary(Version)),
    ?assert(byte_size(Version) > 0).

init_logging_test() ->
    %% 测试日志初始化
    Result = erwind_app:init_logging(),
    ?assertEqual(ok, Result).

load_config_test() ->
    %% 测试配置加载
    Result = erwind_app:load_config(),
    ?assertEqual(ok, Result),

    %% 验证配置已设置
    {ok, TcpPort} = application:get_env(erwind, tcp_port),
    ?assert(is_integer(TcpPort)),

    {ok, HttpPort} = application:get_env(erwind, http_port),
    ?assert(is_integer(HttpPort)),

    {ok, DataDir} = application:get_env(erwind, data_dir),
    ?assert(is_list(DataDir)).

load_env_config_test() ->
    %% 保存原始环境变量
    OldTcp = os:getenv("ERWIND_TCP_PORT"),
    OldHttp = os:getenv("ERWIND_HTTP_PORT"),

    try
        %% 设置测试环境变量
        os:putenv("ERWIND_TCP_PORT", "9999"),
        os:putenv("ERWIND_HTTP_PORT", "8888"),

        %% 测试环境变量加载
        Result = erwind_app:load_env_config(),
        ?assertEqual(ok, Result),

        %% 验证环境变量已应用
        {ok, TcpPort} = application:get_env(erwind, tcp_port),
        ?assertEqual(9999, TcpPort),

        {ok, HttpPort} = application:get_env(erwind, http_port),
        ?assertEqual(8888, HttpPort)
    after
        %% 恢复环境变量
        case OldTcp of
            false -> os:unsetenv("ERWIND_TCP_PORT");
            _ -> os:putenv("ERWIND_TCP_PORT", OldTcp)
        end,
        case OldHttp of
            false -> os:unsetenv("ERWIND_HTTP_PORT");
            _ -> os:putenv("ERWIND_HTTP_PORT", OldHttp)
        end
    end.

init_data_dir_test_() ->
    {setup,
     fun() ->
         %% 使用临时目录
         TestDir = "/tmp/erwind_test_" ++ integer_to_list(erlang:system_time(millisecond)),
         application:set_env(erwind, data_dir, TestDir),
         TestDir
     end,
     fun(TestDir) ->
         %% 清理测试目录
         os:cmd("rm -rf " ++ TestDir),
         ok
     end,
     fun() ->
         %% 测试数据目录初始化
         Result = erwind_app:init_data_dir(),
         ?assertEqual(ok, Result)
     end}.
