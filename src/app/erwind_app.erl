%% erwind_app.erl
%% Erwind 应用程序回调模块

-module(erwind_app).
-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% Public API
-export([version/0, init_logging/0, load_config/0, load_env_config/0, init_data_dir/0]).

%% =============================================================================
%% Application callbacks
%% =============================================================================

%% 启动应用程序
-spec start(StartType :: application:start_type(), StartArgs :: term()) ->
    {ok, pid()} | {ok, pid(), State :: term()} | {error, Reason :: term()}.
start(_StartType, _StartArgs) ->
    logger:info("Starting Erwind application"),

    %% 初始化日志
    ok = init_logging(),

    %% 加载配置
    ok = load_config(),

    %% 从环境变量加载配置
    ok = load_env_config(),

    %% 创建数据目录
    ok = init_data_dir(),

    %% 启动根监督者
    case erwind_sup:start_link() of
        {ok, Pid} ->
            logger:info("Erwind ~s started successfully", [version()]),
            {ok, Pid};
        {ok, Pid, State} ->
            logger:info("Erwind ~s started successfully", [version()]),
            {ok, Pid, State};
        {error, Reason} = Error ->
            logger:error("Erwind failed to start: ~p", [Reason]),
            Error;
        ignore ->
            logger:error("Erwind failed to start: ignored"),
            {error, ignored}
    end.

%% 停止应用程序
-spec stop(State :: term()) -> ok.
stop(_State) ->
    logger:info("Stopping Erwind application"),
    ok.

%% =============================================================================
%% Public API
%% =============================================================================

%% 获取版本号
-spec version() -> binary().
version() ->
    case application:get_key(erwind, vsn) of
        {ok, Vsn} when is_list(Vsn) ->
            VsnStr = lists:flatten(Vsn),
            list_to_binary(VsnStr);
        _ -> <<"0.0.0">>
    end.

%% 初始化日志
-spec init_logging() -> ok.
init_logging() ->
    %% 配置 logger 级别
    LogLevel = case application:get_env(erwind, log_level) of
        {ok, Level} when Level =:= debug; Level =:= info; Level =:= notice;
                         Level =:= warning; Level =:= error; Level =:= critical;
                         Level =:= alert; Level =:= emergency; Level =:= all;
                         Level =:= none -> Level;
        undefined -> info;
        _ -> info
    end,
    logger:set_primary_config(level, LogLevel),
    ok.

%% 加载配置
-spec load_config() -> ok.
load_config() ->
    %% TCP 端口配置
    case application:get_env(erwind, tcp_port) of
        undefined -> application:set_env(erwind, tcp_port, 4150);
        _ -> ok
    end,

    %% HTTP 端口配置
    case application:get_env(erwind, http_port) of
        undefined -> application:set_env(erwind, http_port, 4151);
        _ -> ok
    end,

    %% 消息超时配置
    case application:get_env(erwind, default_msg_timeout) of
        undefined -> application:set_env(erwind, default_msg_timeout, 60000);
        _ -> ok
    end,

    %% 最大消息大小配置
    case application:get_env(erwind, max_msg_size) of
        undefined -> application:set_env(erwind, max_msg_size, 1048576);
        _ -> ok
    end,

    %% 数据目录配置
    case application:get_env(erwind, data_dir) of
        undefined -> application:set_env(erwind, data_dir, "/var/lib/erwind");
        _ -> ok
    end,

    %% Lookupd 地址配置
    case application:get_env(erwind, nsqlookupd_tcp_addresses) of
        undefined -> application:set_env(erwind, nsqlookupd_tcp_addresses, []);
        _ -> ok
    end,

    %% 广播地址配置
    case application:get_env(erwind, broadcast_address) of
        undefined -> application:set_env(erwind, broadcast_address, "127.0.0.1");
        _ -> ok
    end,

    ok.

%% 从环境变量加载配置
-spec load_env_config() -> ok.
load_env_config() ->
    %% ERWIND_TCP_PORT
    case os:getenv("ERWIND_TCP_PORT") of
        false -> ok;
        TcpPortStr ->
            try
                TcpPortNum = list_to_integer(TcpPortStr),
                application:set_env(erwind, tcp_port, TcpPortNum),
                logger:info("Loaded tcp_port from env: ~p", [TcpPortNum])
            catch
                _:_ -> logger:warning("Invalid ERWIND_TCP_PORT: ~s", [TcpPortStr])
            end
    end,

    %% ERWIND_HTTP_PORT
    case os:getenv("ERWIND_HTTP_PORT") of
        false -> ok;
        HttpPortStr ->
            try
                HttpPortNum = list_to_integer(HttpPortStr),
                application:set_env(erwind, http_port, HttpPortNum),
                logger:info("Loaded http_port from env: ~p", [HttpPortNum])
            catch
                _:_ -> logger:warning("Invalid ERWIND_HTTP_PORT: ~s", [HttpPortStr])
            end
    end,

    %% ERWIND_DATA_DIR
    case os:getenv("ERWIND_DATA_DIR") of
        false -> ok;
        Dir ->
            application:set_env(erwind, data_dir, Dir),
            logger:info("Loaded data_dir from env: ~s", [Dir])
    end,

    %% ERWIND_LOG_LEVEL
    case os:getenv("ERWIND_LOG_LEVEL") of
        false -> ok;
        LevelStr ->
            LogLevelAtom = list_to_atom(LevelStr),
            %% 验证是否为有效的日志级别
            ValidLevels = [debug, info, notice, warning, error, critical, alert, emergency, all, none],
            LogLevel = case lists:member(LogLevelAtom, ValidLevels) of
                true -> LogLevelAtom;
                false -> info
            end,
            application:set_env(erwind, log_level, LogLevel),
            logger:set_primary_config(level, LogLevel),
            logger:info("Loaded log_level from env: ~p", [LogLevel])
    end,

    %% ERWIND_LOOKUPD_ADDRS
    case os:getenv("ERWIND_LOOKUPD_ADDRS") of
        false -> ok;
        Addrs ->
            AddrList = string:lexemes(Addrs, ","),
            application:set_env(erwind, nsqlookupd_tcp_addresses, AddrList),
            logger:info("Loaded nsqlookupd_tcp_addresses from env: ~p", [AddrList])
    end,

    ok.

%% 初始化数据目录
-spec init_data_dir() -> ok | {error, term()}.
init_data_dir() ->
    DataDir0 = case application:get_env(erwind, data_dir) of
        {ok, D} when is_list(D) -> D;
        {ok, D} when is_binary(D) -> unicode:characters_to_list(D);
        undefined -> "/var/lib/erwind";
        _ -> "/var/lib/erwind"
    end,
    %% 确保是有效的文件路径类型
    DataDir = unicode:characters_to_list(DataDir0),
    %% 确保目录存在
    case filelib:ensure_dir(filename:join(DataDir, ".")) of
        ok ->
            logger:info("Data directory initialized: ~s", [DataDir]),
            ok;
        {error, Reason} = Error ->
            logger:error("Failed to create data directory ~s: ~p", [DataDir, Reason]),
            Error
    end.
