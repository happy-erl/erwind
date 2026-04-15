%% erwind_acceptor_pool_sup.erl
%% Acceptor 池监督者 - 管理多个 acceptor 进程

-module(erwind_acceptor_pool_sup).
-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%% =============================================================================
%% API
%% =============================================================================

%% 启动 Acceptor 池监督者
-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% =============================================================================
%% Supervisor callbacks
%% =============================================================================

init([]) ->
    SupFlags = #{
        %% one_for_one: 单个 acceptor 崩溃只重启它自己
        strategy => one_for_one,
        intensity => 60,
        period => 60
    },

    %% 获取 Acceptor 池大小
    PoolSize = case application:get_env(erwind, acceptor_pool_size) of
        {ok, Size} when is_integer(Size), Size > 0 -> Size;
        _ -> 10
    end,

    %% 预定义的 acceptor 规格 - 每个有唯一的 Id
    AcceptorSpecs = [
        #{
            id => {erwind_acceptor, N},
            start => {erwind_acceptor, start_link, [N]},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [erwind_acceptor]
        }
        || N <- lists:seq(1, PoolSize)
    ],

    {ok, {SupFlags, AcceptorSpecs}}.
