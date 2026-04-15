%% erwind_tcp_sup.erl
%% TCP 模块监督者

-module(erwind_tcp_sup).
-behaviour(supervisor).

%% API
-export([start_link/0, start_link/1]).

%% Supervisor callbacks
-export([init/1]).

-define(DEFAULT_TCP_PORT, 4150).

%% =============================================================================
%% API
%% =============================================================================

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    Port = case application:get_env(erwind, tcp_port) of
        {ok, P} when is_integer(P) -> P;
        _ -> ?DEFAULT_TCP_PORT
    end,
    start_link(Port).

-spec start_link(Port :: inet:port_number()) -> supervisor:startlink_ret().
start_link(Port) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [Port]).

%% =============================================================================
%% Supervisor callbacks
%% =============================================================================

init([Port]) ->
    SupFlags = #{
        %% rest_for_one: 如果 listener 重启，后面的子进程也重启
        strategy => rest_for_one,
        intensity => 10,
        period => 60
    },

    Children = [
        %% 1. TCP 监听器 - 必须先启动，创建监听 socket
        #{
            id => erwind_tcp_listener,
            start => {erwind_tcp_listener, start_link, [Port]},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [erwind_tcp_listener]
        },

        %% 2. Acceptor 池监督者
        #{
            id => erwind_acceptor_pool_sup,
            start => {erwind_acceptor_pool_sup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [erwind_acceptor_pool_sup]
        },

        %% 3. 连接进程监督者
        #{
            id => erwind_connection_sup,
            start => {erwind_connection_sup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [erwind_connection_sup]
        }
    ],

    {ok, {SupFlags, Children}}.
