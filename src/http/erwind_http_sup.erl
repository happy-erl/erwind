%% erwind_http_sup.erl
%% HTTP 监督者模块
%% 负责启动和管理 Cowboy HTTP 服务器

-module(erwind_http_sup).
-behaviour(supervisor).

%% API
-export([start_link/0, stop/0]).

%% Supervisor callbacks
-export([init/1]).

%% =============================================================================
%% API
%% =============================================================================

%% 启动 HTTP 监督者
-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% 停止 HTTP 服务器
-spec stop() -> ok.
stop() ->
    case whereis(?MODULE) of
        undefined -> ok;
        _Pid ->
            supervisor:terminate_child(?MODULE, cowboy_clear),
            ok
    end.

%% =============================================================================
%% Supervisor callbacks
%% =============================================================================

init([]) ->
    %% 确保 ranch 应用已启动
    case application:start(ranch) of
        ok -> ok;
        {error, {already_started, _}} -> ok;
        Error -> logger:warning("Failed to start ranch: ~p", [Error])
    end,

    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 60
    },

    %% 编译 Cowboy 路由
    Dispatch = cowboy_router:compile([
        {'_', erwind_http_api:routes()}
    ]),

    %% 获取配置
    HttpPort = application:get_env(erwind, http_port, 4151),
    MaxConnections = application:get_env(erwind, http_max_connections, 1000),
    IdleTimeout = application:get_env(erwind, http_idle_timeout, 60000),

    logger:info("Starting HTTP API on port ~p", [HttpPort]),

    %% Cowboy 服务器配置 (新 map 语法)
    CowboyOpts = #{
        env => #{dispatch => Dispatch},
        max_keepalive => 100,
        request_timeout => IdleTimeout,
        idle_timeout => IdleTimeout
    },

    %% Transport 配置 (新 map 语法)
    TransportOpts = #{
        socket_opts => [
            {port, HttpPort}
        ],
        max_connections => MaxConnections
    },

    Children = [
        %% Cowboy HTTP 监听器
        #{
            id => cowboy_clear,
            start => {cowboy, start_clear,
                      [erwind_http_listener, TransportOpts, CowboyOpts]},
            restart => permanent,
            shutdown => infinity,
            type => worker,
            modules => [cowboy]
        }
    ],

    {ok, {SupFlags, Children}}.
