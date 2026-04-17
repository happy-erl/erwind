%% erwind_topic_sup.erl
%% Topic 监督者 - 使用 simple_one_for_one 策略动态创建 Topic

-module(erwind_topic_sup).
-behaviour(supervisor).

%% API
-export([start_link/0, start_topic/1, get_or_create_topic/1, delete_topic/1]).

%% Supervisor callbacks
-export([init/1]).

%% =============================================================================
%% API
%% =============================================================================

%% 启动 Topic 监督者
-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% 启动单个 Topic
-spec start_topic(binary()) -> supervisor:startchild_ret().
start_topic(TopicName) when is_binary(TopicName) ->
    supervisor:start_child(?MODULE, [TopicName]).

%% 获取或创建 Topic
-spec get_or_create_topic(binary()) -> {ok, pid()} | {error, term()}.
get_or_create_topic(TopicName) when is_binary(TopicName) ->
    case erwind_topic_registry:lookup_topic(TopicName) of
        {ok, Pid} when is_pid(Pid) ->
            {ok, Pid};
        not_found ->
            case start_topic(TopicName) of
                {ok, Pid} when is_pid(Pid) ->
                    {ok, Pid};
                {ok, Pid, _Info} when is_pid(Pid) ->
                    {ok, Pid};
                {error, {already_started, Pid}} when is_pid(Pid) ->
                    {ok, Pid};
                {error, Reason} ->
                    {error, Reason}
            end
    end.

%% 删除 Topic
-spec delete_topic(binary()) -> ok | {error, term()}.
delete_topic(TopicName) when is_binary(TopicName) ->
    case erwind_topic_registry:lookup_topic(TopicName) of
        {ok, Pid} ->
            supervisor:terminate_child(?MODULE, Pid),
            ok;
        not_found ->
            {error, not_found}
    end.

%% =============================================================================
%% Supervisor callbacks
%% =============================================================================

init([]) ->
    %% 初始化 Topic 注册表
    erwind_topic_registry:init(),

    SupFlags = #{
        %% simple_one_for_one: 动态子进程，统一规格
        strategy => simple_one_for_one,
        intensity => 10,
        period => 10
    },

    %% Topic 进程规格
    TopicSpec = #{
        id => erwind_topic,
        start => {erwind_topic, start_link, []},
        restart => temporary,  %% Topic 可关闭，不自动重启
        shutdown => 5000,
        type => worker,
        modules => [erwind_topic]
    },

    {ok, {SupFlags, [TopicSpec]}}.
