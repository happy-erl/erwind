%% erwind_channel_sup.erl
%% Channel 监督者 - 使用 simple_one_for_one 策略动态创建 Channel

-module(erwind_channel_sup).
-behaviour(supervisor).

%% API
-export([start_link/0, start_channel/2, stop_channel/1]).

%% Supervisor callbacks
-export([init/1]).

%% =============================================================================
%% API
%% =============================================================================

%% 启动 Channel 监督者
-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% 启动单个 Channel
-spec start_channel(binary(), binary()) -> supervisor:startchild_ret().
start_channel(TopicName, ChannelName) when is_binary(TopicName), is_binary(ChannelName) ->
    supervisor:start_child(?MODULE, [TopicName, ChannelName]).

%% 停止 Channel
-spec stop_channel(pid()) -> ok | {error, term()}.
stop_channel(Pid) when is_pid(Pid) ->
    supervisor:terminate_child(?MODULE, Pid).

%% =============================================================================
%% Supervisor callbacks
%% =============================================================================

init([]) ->
    SupFlags = #{
        %% simple_one_for_one: 动态子进程，统一规格
        strategy => simple_one_for_one,
        intensity => 100,
        period => 60
    },

    %% Channel 进程规格
    ChannelSpec = #{
        id => erwind_channel,
        start => {erwind_channel, start_link, []},
        restart => temporary,  %% Channel 可关闭，不自动重启
        shutdown => 5000,
        type => worker,
        modules => [erwind_channel]
    },

    {ok, {SupFlags, [ChannelSpec]}}.
