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
        },

        %% Topic 监督者
        #{
            id => erwind_topic_sup,
            start => {erwind_topic_sup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [erwind_topic_sup]
        },

        %% Channel 监督者
        #{
            id => erwind_channel_sup,
            start => {erwind_channel_sup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [erwind_channel_sup]
        },

        %% 统计模块
        #{
            id => erwind_stats,
            start => {erwind_stats, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [erwind_stats]
        },

        %% Lookupd 客户端
        #{
            id => erwind_lookupd,
            start => {erwind_lookupd, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [erwind_lookupd]
        },

        %% HTTP API 监督者
        #{
            id => erwind_http_sup,
            start => {erwind_http_sup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [erwind_http_sup]
        }
    ],

    {ok, {SupFlags, Children}}.
