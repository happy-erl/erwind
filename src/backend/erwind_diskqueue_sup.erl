%% erwind_diskqueue_sup.erl
%% 磁盘队列监督者 - 使用 simple_one_for_one 策略动态创建磁盘队列

-module(erwind_diskqueue_sup).
-behaviour(supervisor).

%% API
-export([start_link/0, stop/0, start_queue/1, stop_queue/1]).
-export([get_queue/1, list_queues/0]).

%% Supervisor callbacks
-export([init/1]).

-define(TABLE_NAME, erwind_diskqueue_registry).

%% =============================================================================
%% API
%% =============================================================================

%% 启动监督者
-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% 停止监督者
-spec stop() -> ok.
stop() ->
    case whereis(?MODULE) of
        undefined -> ok;
        Pid ->
            exit(Pid, normal),
            ok
    end.

%% 启动磁盘队列
-spec start_queue(binary()) -> supervisor:startchild_ret().
start_queue(Name) when is_binary(Name) ->
    case get_queue(Name) of
        {ok, Pid} ->
            {ok, Pid};
        not_found ->
            Result = supervisor:start_child(?MODULE, [Name]),
            case Result of
                {ok, Pid} when is_pid(Pid) ->
                    ets:insert(?TABLE_NAME, {Name, Pid}),
                    {ok, Pid};
                {ok, Pid, _Info} when is_pid(Pid) ->
                    ets:insert(?TABLE_NAME, {Name, Pid}),
                    {ok, Pid};
                {error, {already_started, Pid}} when is_pid(Pid) ->
                    ets:insert(?TABLE_NAME, {Name, Pid}),
                    {ok, Pid};
                _ ->
                    Result
            end
    end.

%% 停止磁盘队列
-spec stop_queue(binary()) -> ok | {error, term()}.
stop_queue(Name) when is_binary(Name) ->
    case get_queue(Name) of
        {ok, Pid} ->
            ets:delete(?TABLE_NAME, Name),
            supervisor:terminate_child(?MODULE, Pid);
        not_found ->
            {error, not_found}
    end.

%% 获取队列 PID
-spec get_queue(binary()) -> {ok, pid()} | not_found.
get_queue(Name) when is_binary(Name) ->
    case ets:lookup(?TABLE_NAME, Name) of
        [{_, Pid}] when is_pid(Pid) ->
            case is_process_alive(Pid) of
                true -> {ok, Pid};
                false ->
                    ets:delete(?TABLE_NAME, Name),
                    not_found
            end;
        [] ->
            not_found
    end.

%% 列出所有队列
-spec list_queues() -> [{binary(), pid()}].
list_queues() ->
    ets:tab2list(?TABLE_NAME).

%% =============================================================================
%% Supervisor callbacks
%% =============================================================================

init([]) ->
    %% 初始化注册表 ETS
    case ets:info(?TABLE_NAME) of
        undefined ->
            ets:new(?TABLE_NAME, [
                set,
                named_table,
                public,
                {read_concurrency, true}
            ]);
        _ ->
            ets:delete_all_objects(?TABLE_NAME)
    end,

    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 10,
        period => 10
    },

    DiskQueueSpec = #{
        id => erwind_disk_queue,
        start => {erwind_disk_queue, start_link, []},
        restart => temporary,
        shutdown => 5000,
        type => worker,
        modules => [erwind_disk_queue]
    },

    {ok, {SupFlags, [DiskQueueSpec]}}.
