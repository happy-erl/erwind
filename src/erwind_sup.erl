%% erwind_sup.erl
%% Erwind 根监督者

-module(erwind_sup).
-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%% =============================================================================
%% API
%% =============================================================================

%% 启动根监督者
-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% =============================================================================
%% Supervisor callbacks
%% =============================================================================

init([]) ->
    SupFlags = #{
        strategy => one_for_all,
        intensity => 10,
        period => 60
    },

    Children = [
        %% TCP 模块监督者
        #{
            id => erwind_tcp_sup,
            start => {erwind_tcp_sup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [erwind_tcp_sup]
        }
        %% TODO: 添加其他监督者
        %% - erwind_topic_sup (Topic 监督者)
        %% - erwind_channel_sup (Channel 监督者)
        %% - erwind_stats (统计模块)
    ],

    {ok, {SupFlags, Children}}.
