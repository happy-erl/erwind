%% erwind_topic_registry.erl
%% Topic 注册表 - ETS 表管理
%% 用于快速查找 Topic PID

-module(erwind_topic_registry).

%% API
-export([init/0, register_topic/2, unregister_topic/1, lookup_topic/1,
         list_topics/0, create_topic/1, delete_topic/1]).

-define(TABLE_NAME, erwind_topic_registry).

%% =============================================================================
%% API
%% =============================================================================

%% 初始化 ETS 表
init() ->
    case ets:info(?TABLE_NAME) of
        undefined ->
            ets:new(?TABLE_NAME, [
                set,                    %% 唯一键
                named_table,           %% 具名表
                public,                %% 公开读写
                {read_concurrency, true}  %% 高并发读优化
            ]);
        _ ->
            %% 表已存在，先删除再重建
            ets:delete(?TABLE_NAME),
            init()
    end.

%% 注册 Topic
-spec register_topic(binary(), pid()) -> true.
register_topic(TopicName, Pid) when is_binary(TopicName), is_pid(Pid) ->
    ets:insert(?TABLE_NAME, {TopicName, Pid}).

%% 注销 Topic
-spec unregister_topic(binary()) -> true.
unregister_topic(TopicName) when is_binary(TopicName) ->
    ets:delete(?TABLE_NAME, TopicName).

%% 查找 Topic
-spec lookup_topic(binary()) -> {ok, pid()} | not_found.
lookup_topic(TopicName) when is_binary(TopicName) ->
    case ets:lookup(?TABLE_NAME, TopicName) of
        [{_, Pid}] -> {ok, Pid};
        [] -> not_found
    end.

%% 列出所有 Topics
-spec list_topics() -> [{binary(), pid()}].
list_topics() ->
    ets:tab2list(?TABLE_NAME).

%% 创建新 Topic
-spec create_topic(binary()) -> {ok, pid()} | {error, term()}.
create_topic(TopicName) when is_binary(TopicName) ->
    case lookup_topic(TopicName) of
        {ok, _Pid} ->
            {error, already_exists};
        not_found ->
            case erwind_topic_sup:start_topic(TopicName) of
                {ok, Pid} when is_pid(Pid) -> {ok, Pid};
                {ok, Pid, _} when is_pid(Pid) -> {ok, Pid};
                {error, {already_started, Pid}} when is_pid(Pid) -> {ok, Pid};
                {error, Reason} -> {error, Reason};
                _ -> {error, unknown}
            end
    end.

%% 删除 Topic 条目
-spec delete_topic(binary()) -> ok | {error, term()}.
delete_topic(TopicName) when is_binary(TopicName) ->
    case lookup_topic(TopicName) of
        {ok, Pid} ->
            ok = erwind_topic:stop(Pid),
            ets:delete(?TABLE_NAME, TopicName),
            ok;
        not_found ->
            {error, not_found}
    end.
