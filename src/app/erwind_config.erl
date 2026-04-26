%% erwind_config.erl
%% 配置管理模块 - 运行时配置热更新

-module(erwind_config).

%% API
-export([get/1, get/2, set/2, update/2, reload/0]).
-export([notify_change/2]).

%% =============================================================================
%% API
%% =============================================================================

%% 获取配置值
-spec get(Key :: atom()) -> {ok, term()} | undefined.
get(Key) when is_atom(Key) ->
    application:get_env(erwind, Key).

%% 获取配置值（带默认值）
-spec get(Key :: atom(), Default :: term()) -> term().
get(Key, Default) when is_atom(Key) ->
    application:get_env(erwind, Key, Default).

%% 设置配置值
-spec set(Key :: atom(), Value :: term()) -> ok.
set(Key, Value) when is_atom(Key) ->
    application:set_env(erwind, Key, Value),
    ok.

%% 更新配置并通知变更
-spec update(Key :: atom(), Value :: term()) -> ok.
update(Key, Value) when is_atom(Key) ->
    OldValue = application:get_env(erwind, Key),
    application:set_env(erwind, Key, Value),
    notify_change(Key, {OldValue, Value}),
    logger:info("Config updated: ~p = ~p", [Key, Value]),
    ok.

%% 重新加载配置文件
-spec reload() -> ok | {error, term()}.
reload() ->
    %% 查找配置文件
    PrivDir = case code:priv_dir(erwind) of
        {error, _} -> ".";
        Dir when is_list(Dir) -> Dir
    end,
    ConfigFiles = [
        "config/sys.config",
        "/etc/erwind/sys.config",
        filename:join(PrivDir, "sys.config")
    ],
    case find_config_file(ConfigFiles) of
        {ok, ConfigFile} ->
            do_reload(ConfigFile);
        {error, not_found} ->
            {error, config_file_not_found}
    end.

%% 通知配置变更
-spec notify_change(atom(), term()) -> ok.
notify_change(tcp_port, {_Old, NewPort}) when is_integer(NewPort) ->
    %% TCP 端口变更需要重启监听器
    logger:info("TCP port config changed to ~p, will take effect on restart", [NewPort]),
    ok;
notify_change(http_port, {_Old, NewPort}) when is_integer(NewPort) ->
    %% HTTP 端口变更需要重启 HTTP 服务
    logger:info("HTTP port config changed to ~p, will take effect on restart", [NewPort]),
    ok;
notify_change(log_level, {_Old, NewLevel}) when NewLevel =:= debug; NewLevel =:= info;
                                                          NewLevel =:= notice; NewLevel =:= warning;
                                                          NewLevel =:= error; NewLevel =:= critical;
                                                          NewLevel =:= alert; NewLevel =:= emergency;
                                                          NewLevel =:= all; NewLevel =:= none ->
    %% 日志级别可以热更新
    logger:set_primary_config(level, NewLevel),
    logger:info("Log level changed to ~p", [NewLevel]),
    ok;
notify_change(max_msg_size, {_Old, NewSize}) when is_integer(NewSize), NewSize > 0 ->
    logger:info("Max message size changed to ~p", [NewSize]),
    ok;
notify_change(default_msg_timeout, {_Old, NewTimeout}) when is_integer(NewTimeout), NewTimeout > 0 ->
    logger:info("Default message timeout changed to ~p", [NewTimeout]),
    ok;
notify_change(stats_enabled, {_Old, Enabled}) ->
    logger:info("Stats enabled changed to ~p", [Enabled]),
    ok;
notify_change(_, _) ->
    %% 其他配置变更不需要特殊处理
    ok.

%% =============================================================================
%% Internal functions
%% =============================================================================

%% 查找配置文件
find_config_file([]) ->
    {error, not_found};
find_config_file([File | Rest]) ->
    case filelib:is_file(File) of
        true -> {ok, File};
        false -> find_config_file(Rest)
    end.

%% 执行重载
do_reload(ConfigFile) ->
    case file:consult(ConfigFile) of
        {ok, [Config]} when is_list(Config) ->
            case proplists:get_value(erwind, Config) of
                undefined ->
                    {error, no_erwind_config};
                ErwindConfig when is_list(ErwindConfig) ->
                    apply_config(ErwindConfig),
                    logger:info("Configuration reloaded from ~s", [ConfigFile]),
                    ok
            end;
        {ok, _} ->
            {error, invalid_config_format};
        {error, Reason} ->
            {error, {consult_failed, Reason}}
    end.

%% 应用配置
apply_config([]) -> ok;
apply_config([{Key, Value} | Rest]) when is_atom(Key) ->
    update(Key, Value),
    apply_config(Rest);
apply_config([_ | Rest]) ->
    apply_config(Rest).
