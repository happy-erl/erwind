%% erwind_connection_sup.erl
%% 连接进程监督者 - 使用 simple_one_for_one 策略动态管理连接

-module(erwind_connection_sup).
-behaviour(supervisor).

%% API
-export([start_link/0, start_connection/1]).

%% Supervisor callbacks
-export([init/1]).

%% =============================================================================
%% API
%% =============================================================================

%% 启动连接监督者
-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% 动态启动新连接进程
-spec start_connection(Socket :: inet:socket()) -> supervisor:startchild_ret().
start_connection(Socket) ->
    supervisor:start_child(?MODULE, [Socket]).

%% =============================================================================
%% Supervisor callbacks
%% =============================================================================

init([]) ->
    SupFlags = #{
        %% simple_one_for_one: 动态子进程，统一规格
        strategy => simple_one_for_one,
        intensity => 10000,
        period => 60
    },

    %% 连接进程规格 - 动态参数为 Socket
    ConnectionSpec = #{
        id => erwind_connection,
        start => {erwind_connection, start_link, []},
        restart => temporary,  %% 连接进程不自动重启
        shutdown => 5000,
        type => worker,
        modules => [erwind_connection]
    },

    {ok, {SupFlags, [ConnectionSpec]}}.
