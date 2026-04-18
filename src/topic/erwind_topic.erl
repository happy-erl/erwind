%% erwind_topic.erl
%% Topic 模块 - 消息逻辑通道
%% 负责接收生产者消息并分发给 Channels

-module(erwind_topic).
-behaviour(gen_server).

%% API
-export([start_link/1, stop/1, publish/2, mpub/2, dpub/3]).
-export([get_channel/2, create_channel/2, delete_channel/2, list_channels/1]).
-export([get_stats/1, pause/1, unpause/1, is_paused/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% Internal exports
-export([create_message/1, is_ephemeral/1]).

-include_lib("erwind/include/erwind.hrl").

-record(state, {
    name :: binary(),                           %% Topic 名称
    channels = #{} :: #{binary() => pid()},     %% Channel 名称 -> PID 映射
    backend :: pid() | undefined,               %% Backend Queue PID
    message_count = 0 :: non_neg_integer(),     %% 消息计数
    paused = false :: boolean(),                %% 是否暂停
    ephemeral = false :: boolean(),             %% 是否临时 Topic
    stats = #{} :: map(),                       %% 统计信息
    deferred_msgs = #{} :: #{reference() => #nsq_message{}}  %% 延迟消息
}).

%% =============================================================================
%% API
%% =============================================================================

%% 启动 Topic 进程
-spec start_link(binary()) -> gen_server:start_ret().
start_link(TopicName) when is_binary(TopicName) ->
    gen_server:start_link(?MODULE, [TopicName], []).

%% 停止 Topic
-spec stop(pid()) -> ok.
stop(Pid) when is_pid(Pid) ->
    gen_server:stop(Pid).

%% 发布单条消息（异步）
-spec publish(pid() | binary(), binary()) -> ok | {error, term()}.
publish(TopicPid, Body) when is_pid(TopicPid), is_binary(Body) ->
    gen_server:cast(TopicPid, {publish, Body});
publish(TopicName, Body) when is_binary(TopicName), is_binary(Body) ->
    case erwind_topic_registry:lookup_topic(TopicName) of
        {ok, Pid} -> publish(Pid, Body);
        not_found -> {error, topic_not_found}
    end.

%% 批量发布（异步）
-spec mpub(pid() | binary(), [binary()]) -> ok | {error, term()}.
mpub(TopicPid, Bodies) when is_pid(TopicPid), is_list(Bodies) ->
    gen_server:cast(TopicPid, {mpub, Bodies});
mpub(TopicName, Bodies) when is_binary(TopicName), is_list(Bodies) ->
    case erwind_topic_registry:lookup_topic(TopicName) of
        {ok, Pid} -> mpub(Pid, Bodies);
        not_found -> {error, topic_not_found}
    end.

%% 延迟发布
-spec dpub(pid() | binary(), binary(), non_neg_integer()) -> ok | {error, term()}.
dpub(TopicPid, Body, DeferMs) when is_pid(TopicPid), is_binary(Body), is_integer(DeferMs) ->
    gen_server:cast(TopicPid, {dpub, Body, DeferMs});
dpub(TopicName, Body, DeferMs) when is_binary(TopicName), is_binary(Body), is_integer(DeferMs) ->
    case erwind_topic_registry:lookup_topic(TopicName) of
        {ok, Pid} -> dpub(Pid, Body, DeferMs);
        not_found -> {error, topic_not_found}
    end.

%% 获取或创建 Channel
-spec get_channel(pid(), binary()) -> {ok, pid()}.
get_channel(TopicPid, ChannelName) when is_pid(TopicPid), is_binary(ChannelName) ->
    case gen_server:call(TopicPid, {get_channel, ChannelName}) of
        {ok, Pid} when is_pid(Pid) -> {ok, Pid}
    end.

%% 创建 Channel
-spec create_channel(pid(), binary()) -> {ok, pid()} | {error, term()}.
create_channel(TopicPid, ChannelName) when is_pid(TopicPid), is_binary(ChannelName) ->
    Result = gen_server:call(TopicPid, {create_channel, ChannelName}),
    %% Type guard for eqwalizer
    case Result of
        {ok, Pid} when is_pid(Pid) -> Result;
        {error, _} -> Result
    end.

%% 删除 Channel
-spec delete_channel(pid(), binary()) -> ok | {error, term()}.
delete_channel(TopicPid, ChannelName) when is_pid(TopicPid), is_binary(ChannelName) ->
    Result = gen_server:call(TopicPid, {delete_channel, ChannelName}),
    %% Type guard for eqwalizer
    case Result of
        ok -> ok;
        {error, _} -> Result
    end.

%% 列出所有 Channels
-spec list_channels(pid()) -> [{binary(), pid()}].
list_channels(TopicPid) when is_pid(TopicPid) ->
    Result = gen_server:call(TopicPid, list_channels),
    %% Type guard for eqwalizer
    [{Topic, Pid} || {Topic, Pid} <- Result, is_binary(Topic), is_pid(Pid)].

%% 获取统计信息
-spec get_stats(pid()) -> map().
get_stats(TopicPid) when is_pid(TopicPid) ->
    Result = gen_server:call(TopicPid, get_stats),
    %% Type guard for eqwalizer
    true = is_map(Result),
    Result.

%% 暂停 Topic
-spec pause(pid()) -> ok.
pause(TopicPid) when is_pid(TopicPid) ->
    Result = gen_server:call(TopicPid, pause),
    %% Type guard for eqwalizer
    ok = Result.

%% 恢复 Topic
-spec unpause(pid()) -> ok.
unpause(TopicPid) when is_pid(TopicPid) ->
    Result = gen_server:call(TopicPid, unpause),
    %% Type guard for eqwalizer
    ok = Result.

%% 检查是否暂停
-spec is_paused(pid()) -> boolean().
is_paused(TopicPid) when is_pid(TopicPid) ->
    Result = gen_server:call(TopicPid, is_paused),
    %% Type guard for eqwalizer
    true = is_boolean(Result),
    Result.

%% =============================================================================
%% gen_server callbacks
%% =============================================================================

init([TopicName]) ->
    process_flag(trap_exit, true),

    %% 启动 Backend Queue（如果存在该模块）
    BackendPid = case code:which(erwind_backend_queue) of
        non_existing -> undefined;
        _ ->
            case erwind_backend_queue:start_link(TopicName) of
                {ok, Pid} -> Pid;
                _ -> undefined
            end
    end,

    %% 注册到 ETS
    erwind_topic_registry:register_topic(TopicName, self()),

    %% 通知 nsqlookupd（如果存在该模块）
    case code:which(erwind_lookupd) of
        non_existing -> ok;
        _ -> erwind_lookupd:register_topic(TopicName)
    end,

    logger:info("Topic ~s started", [TopicName]),

    {ok, #state{
        name = TopicName,
        backend = BackendPid,
        ephemeral = is_ephemeral(TopicName)
    }}.

handle_call({get_channel, ChannelName}, _From, State) ->
    case maps:get(ChannelName, State#state.channels, undefined) of
        undefined ->
            %% 创建新 Channel
            case create_channel_internal(ChannelName, State) of
                {ok, Pid, NewState} ->
                    {reply, {ok, Pid}, NewState};
                {error, Reason} ->
                    {reply, {error, Reason}, State}
            end;
        Pid ->
            {reply, {ok, Pid}, State}
    end;

handle_call({create_channel, ChannelName}, _From, State) ->
    case maps:get(ChannelName, State#state.channels, undefined) of
        undefined ->
            case create_channel_internal(ChannelName, State) of
                {ok, Pid, NewState} ->
                    {reply, {ok, Pid}, NewState};
                {error, Reason} ->
                    {reply, {error, Reason}, State}
            end;
        Pid ->
            {reply, {ok, Pid}, State}
    end;

handle_call({delete_channel, ChannelName}, _From, State) ->
    case maps:get(ChannelName, State#state.channels, undefined) of
        undefined ->
            {reply, {error, not_found}, State};
        Pid ->
            %% 停止 Channel
            case code:which(erwind_channel) of
                non_existing -> ok;
                _ -> erwind_channel:stop(Pid)
            end,
            NewChannels = maps:remove(ChannelName, State#state.channels),
            {reply, ok, State#state{channels = NewChannels}}
    end;

handle_call(list_channels, _From, State) ->
    {reply, maps:to_list(State#state.channels), State};

handle_call(get_stats, _From, State) ->
    Stats = #{
        name => State#state.name,
        message_count => State#state.message_count,
        channel_count => map_size(State#state.channels),
        paused => State#state.paused,
        ephemeral => State#state.ephemeral
    },
    {reply, Stats, State};

handle_call(pause, _From, State) ->
    logger:info("Topic ~s paused", [State#state.name]),
    {reply, ok, State#state{paused = true}};

handle_call(unpause, _From, State) ->
    logger:info("Topic ~s unpaused", [State#state.name]),
    {reply, ok, State#state{paused = false}};

handle_call(is_paused, _From, State) ->
    {reply, State#state.paused, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

%% 发布消息（检查暂停状态）
handle_cast({publish, _Body}, #state{paused = true} = State) ->
    %% Topic 已暂停，拒绝消息
    logger:warning("Topic ~s is paused, message rejected", [State#state.name]),
    {noreply, State};

handle_cast({publish, Body}, State) when is_binary(Body) ->
    Msg = create_message(Body),

    %% 写入 Backend Queue
    case State#state.backend of
        undefined -> ok;
        BackendPid -> erwind_backend_queue:put(BackendPid, Msg)
    end,

    %% 分发到所有 Channel
    distribute_message(Msg, State#state.channels),

    %% 更新统计
    update_stats(State#state.name),

    {noreply, State#state{
        message_count = State#state.message_count + 1
    }};

%% 批量发布
handle_cast({mpub, Bodies}, State) when is_list(Bodies) ->
    Msgs = [create_message(Body) || Body <- Bodies],

    %% 批量写入 Backend
    case State#state.backend of
        undefined -> ok;
        BackendPid -> erwind_backend_queue:put_batch(BackendPid, Msgs)
    end,

    %% 批量分发
    lists:foreach(fun(Msg) ->
        distribute_message(Msg, State#state.channels)
    end, Msgs),

    %% 更新统计
    lists:foreach(fun(_) -> update_stats(State#state.name) end, Msgs),

    {noreply, State#state{
        message_count = State#state.message_count + length(Msgs)
    }};

%% 延迟发布
handle_cast({dpub, Body, DeferMs}, State) when is_binary(Body), is_integer(DeferMs) ->
    Msg = create_message(Body),

    %% 设置延迟定时器
    TimerRef = erlang:send_after(DeferMs, self(), {deferred_publish, Msg}),

    %% 存储延迟消息
    DeferredMsgs = maps:put(TimerRef, Msg, State#state.deferred_msgs),

    {noreply, State#state{deferred_msgs = DeferredMsgs}};

handle_cast(_Request, State) ->
    {noreply, State}.

%% 延迟到期处理
handle_info({deferred_publish, Msg}, State) ->
    %% 移除已触发的定时器
    DeferredMsgs = maps:filter(fun(_, M) -> M =/= Msg end, State#state.deferred_msgs),

    %% 与普通发布相同逻辑
    case State#state.backend of
        undefined -> ok;
        BackendPid -> erwind_backend_queue:put(BackendPid, Msg)
    end,

    distribute_message(Msg, State#state.channels),
    update_stats(State#state.name),

    {noreply, State#state{
        message_count = State#state.message_count + 1,
        deferred_msgs = DeferredMsgs
    }};

%% Channel 退出处理
handle_info({'DOWN', _Ref, process, Pid, _Reason}, State) ->
    %% 从 channels map 中移除
    NewChannels = maps:filter(fun(_, P) -> P =/= Pid end, State#state.channels),

    logger:info("Topic ~s: channel removed, remaining: ~p",
                [State#state.name, map_size(NewChannels)]),

    %% 检查是否是临时 Topic 且无 Channel
    case State#state.ephemeral andalso map_size(NewChannels) == 0 of
        true ->
            logger:info("Ephemeral topic ~s has no channels, stopping",
                       [State#state.name]),
            {stop, normal, State#state{channels = NewChannels}};
        false ->
            {noreply, State#state{channels = NewChannels}}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    %% 从注册表移除
    erwind_topic_registry:unregister_topic(State#state.name),

    %% 通知 nsqlookupd
    case code:which(erwind_lookupd) of
        non_existing -> ok;
        _ -> erwind_lookupd:unregister_topic(State#state.name)
    end,

    logger:info("Topic ~s stopped", [State#state.name]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =============================================================================
%% Internal functions
%% =============================================================================

%% 创建新消息
-spec create_message(binary()) -> #nsq_message{}.
create_message(Body) ->
    #nsq_message{
        id = erwind_protocol:generate_msg_id(),
        timestamp = erlang:system_time(millisecond),
        attempts = 1,
        body = Body
    }.

%% 分发消息到所有 Channels
distribute_message(_Msg, Channels) when map_size(Channels) == 0 ->
    ok;
distribute_message(Msg, Channels) ->
    maps:foreach(fun(_, Pid) ->
        case code:which(erwind_channel) of
            non_existing -> ok;
            _ -> erwind_channel:put_message(Pid, Msg)
        end
    end, Channels).

%% 创建 Channel 内部函数
create_channel_internal(ChannelName, State) ->
    %% 检查 Channel 数量限制
    MaxChannels = application:get_env(erwind, max_channels_per_topic, 100),
    case map_size(State#state.channels) >= MaxChannels of
        true ->
            {error, too_many_channels};
        false ->
            case code:which(erwind_channel_sup) of
                non_existing ->
                    %% Channel supervisor 不存在，创建 dummy channel
                    {ok, self(), State};
                _ ->
                    case erwind_channel_sup:start_channel(State#state.name, ChannelName) of
                        {ok, Pid} when is_pid(Pid) ->
                            %% 监控 Channel
                            erlang:monitor(process, Pid),
                            NewChannels = maps:merge(#{ChannelName => Pid}, State#state.channels),
                            {ok, Pid, State#state{channels = NewChannels}};
                        {error, Reason} ->
                            {error, Reason}
                    end
            end
    end.

%% 更新统计
update_stats(TopicName) ->
    case code:which(erwind_stats) of
        non_existing -> ok;
        _ -> erwind_stats:incr_topic_msg_count(TopicName)
    end.

%% 判断是否为临时 Topic
-spec is_ephemeral(binary()) -> boolean().
is_ephemeral(TopicName) ->
    binary:longest_common_suffix([TopicName, <<"#ephemeral">>]) == 10.
