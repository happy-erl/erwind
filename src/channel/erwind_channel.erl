%% erwind_channel.erl
%% Channel 模块 - 消费者订阅的消息通道
%% 负责管理消费者列表和消息分发
%%
%% eqwalizer notes: Static type inference limitations exist for gen_server:call
%% and higher-order list operations (lists:map). Runtime type safety is ensured
%% through pattern matching and guards.

-module(erwind_channel).
-behaviour(gen_server).

%% API
-export([start_link/2, stop/1, put_message/2, subscribe/2, unsubscribe/2]).
-export([finish_message/2, requeue_message/3, touch_message/2]).
-export([update_rdy/2, get_consumers/1, get_stats/1]).
-export([get_depth/1, get_consumer_count/1, pause/1, unpause/1, empty/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include_lib("erwind/include/erwind.hrl").

-record(state, {
    topic_name :: binary(),
    channel_name :: binary(),
    consumers = [] :: [#consumer{}],
    message_queue = queue:new() :: queue:queue(#nsq_message{}),    %% 消息队列
    ephemeral = false :: boolean(),
    paused = false :: boolean()
}).

%% =============================================================================
%% API
%% =============================================================================

%% 启动 Channel
-spec start_link(binary(), binary()) -> gen_server:start_ret().
start_link(TopicName, ChannelName) when is_binary(TopicName), is_binary(ChannelName) ->
    gen_server:start_link(?MODULE, [TopicName, ChannelName], []).

%% 停止 Channel
-spec stop(pid()) -> ok.
stop(Pid) when is_pid(Pid) ->
    gen_server:stop(Pid).

%% 投递消息到 Channel
-spec put_message(pid(), #nsq_message{}) -> ok.
put_message(Pid, Msg) when is_pid(Pid), is_record(Msg, nsq_message) ->
    gen_server:cast(Pid, {put_message, Msg}).

%% 订阅 Channel
-spec subscribe(pid(), pid()) -> ok | {error, term()}.
subscribe(Pid, ConsumerPid) when is_pid(Pid), is_pid(ConsumerPid) ->
    Result = gen_server:call(Pid, {subscribe, ConsumerPid}),
    %% Type guard for eqwalizer
    case Result of
        ok -> ok;
        {error, _} = E -> E
    end.

%% 取消订阅
-spec unsubscribe(pid(), pid()) -> ok.
unsubscribe(Pid, ConsumerPid) when is_pid(Pid), is_pid(ConsumerPid) ->
    Result = gen_server:call(Pid, {unsubscribe, ConsumerPid}),
    %% Type guard for eqwalizer
    ok = Result.

%% 完成消息
-spec finish_message(pid(), binary()) -> ok.
finish_message(Pid, MsgId) when is_pid(Pid), is_binary(MsgId) ->
    gen_server:cast(Pid, {finish, MsgId}).

%% 重新入队消息
-spec requeue_message(pid(), binary(), integer()) -> ok.
requeue_message(Pid, MsgId, Timeout) when is_pid(Pid), is_binary(MsgId), is_integer(Timeout) ->
    gen_server:cast(Pid, {requeue, MsgId, Timeout}).

%% 延长消息超时
-spec touch_message(pid(), binary()) -> ok.
touch_message(Pid, MsgId) when is_pid(Pid), is_binary(MsgId) ->
    gen_server:cast(Pid, {touch, MsgId}).

%% 更新 RDY 计数
-spec update_rdy(pid(), integer()) -> ok.
update_rdy(Pid, Count) when is_pid(Pid), is_integer(Count) ->
    gen_server:cast(Pid, {update_rdy, Count}).

%% 获取消费者列表
-spec get_consumers(pid()) -> [pid()].
get_consumers(Pid) when is_pid(Pid) ->
    case gen_server:call(Pid, get_consumers) of
        List when is_list(List) -> [P || P <- List, is_pid(P)];
        _ -> []
    end.

%% 获取统计信息
-spec get_stats(pid()) -> map().
get_stats(Pid) when is_pid(Pid) ->
    Result = gen_server:call(Pid, get_stats),
    %% Type guard for eqwalizer
    true = is_map(Result),
    Result.

%% 获取队列深度
-spec get_depth(pid()) -> non_neg_integer().
get_depth(Pid) when is_pid(Pid) ->
    Result = gen_server:call(Pid, get_depth),
    %% Type guard for eqwalizer
    true = is_integer(Result) andalso Result >= 0,
    Result.

%% 获取消费者数量
-spec get_consumer_count(pid()) -> non_neg_integer().
get_consumer_count(Pid) when is_pid(Pid) ->
    Result = gen_server:call(Pid, get_consumer_count),
    %% Type guard for eqwalizer
    true = is_integer(Result) andalso Result >= 0,
    Result.

%% 暂停 Channel
-spec pause(pid()) -> ok.
pause(Pid) when is_pid(Pid) ->
    Result = gen_server:call(Pid, pause),
    %% Type guard for eqwalizer
    ok = Result.

%% 恢复 Channel
-spec unpause(pid()) -> ok.
unpause(Pid) when is_pid(Pid) ->
    Result = gen_server:call(Pid, unpause),
    %% Type guard for eqwalizer
    ok = Result.

%% 清空 Channel 队列
-spec empty(pid()) -> ok.
empty(Pid) when is_pid(Pid) ->
    Result = gen_server:call(Pid, empty),
    %% Type guard for eqwalizer
    ok = Result.

%% =============================================================================
%% gen_server callbacks
%% =============================================================================

init([TopicName, ChannelName]) ->
    process_flag(trap_exit, true),

    logger:info("Channel ~s/~s started", [TopicName, ChannelName]),

    {ok, #state{
        topic_name = TopicName,
        channel_name = ChannelName,
        ephemeral = is_ephemeral(ChannelName)
    }}.

handle_call({subscribe, ConsumerPid}, _From, State) ->
    %% 检查是否已订阅
    case lists:keyfind(ConsumerPid, #consumer.pid, State#state.consumers) of
        false ->
            %% 监控消费者
            erlang:monitor(process, ConsumerPid),
            Consumer = #consumer{pid = ConsumerPid, rdy = 1},
            NewConsumers = [Consumer | State#state.consumers],
            {reply, ok, State#state{consumers = NewConsumers}};
        _ ->
            {reply, {error, already_subscribed}, State}
    end;

handle_call({unsubscribe, ConsumerPid}, _From, State) ->
    NewConsumers = lists:keydelete(ConsumerPid, #consumer.pid, State#state.consumers),
    %% Type guard for eqwalizer
    true = lists:all(fun(C) -> is_record(C, consumer) end, NewConsumers),
    {reply, ok, State#state{consumers = NewConsumers}};

handle_call(get_consumers, _From, State) ->
    Pids = [C#consumer.pid || C <- State#state.consumers],
    {reply, Pids, State};

handle_call(get_stats, _From, State) ->
    Stats = #{
        topic => State#state.topic_name,
        channel => State#state.channel_name,
        consumer_count => length(State#state.consumers),
        message_queue_len => queue:len(State#state.message_queue),
        paused => State#state.paused,
        ephemeral => State#state.ephemeral
    },
    {reply, Stats, State};

handle_call(get_depth, _From, State) ->
    {reply, queue:len(State#state.message_queue), State};

handle_call(get_consumer_count, _From, State) ->
    {reply, length(State#state.consumers), State};

handle_call(pause, _From, State) ->
    logger:info("Channel ~s/~s paused", [State#state.topic_name, State#state.channel_name]),
    {reply, ok, State#state{paused = true}};

handle_call(unpause, _From, State) ->
    logger:info("Channel ~s/~s unpaused", [State#state.topic_name, State#state.channel_name]),
    {reply, ok, State#state{paused = false}};

handle_call(empty, _From, State) ->
    logger:info("Channel ~s/~s emptied (~p messages discarded)",
               [State#state.topic_name, State#state.channel_name, queue:len(State#state.message_queue)]),
    {reply, ok, State#state{message_queue = queue:new()}};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

%% 投递消息
handle_cast({put_message, Msg}, State) ->
    %% 将消息加入队列
    NewQueue = queue:in(Msg, State#state.message_queue),

    %% 尝试投递给有 RDY 的消费者
    try_deliver_messages(State#state{message_queue = NewQueue});

%% 完成消息
handle_cast({finish, MsgId}, State) ->
    %% 从消费者的 in_flight 中移除
    NewConsumers = remove_from_inflight(State#state.consumers, MsgId),
    {noreply, State#state{consumers = NewConsumers}};

%% 重新入队
handle_cast({requeue, MsgId, Timeout}, State) ->
    %% 从 in_flight 移除并延迟处理
    NewConsumers = mark_for_requeue(State#state.consumers, MsgId, Timeout, self()),
    {noreply, State#state{consumers = NewConsumers}};

%% 延长消息超时
handle_cast({touch, MsgId}, State) ->
    %% 更新 in_flight 消息的超时时间
    NewConsumers = touch_inflight_msgs(State#state.consumers, MsgId),
    {noreply, State#state{consumers = NewConsumers}};

%% 更新 RDY
handle_cast({update_rdy, Count}, State) when is_integer(Count), Count >= 0 ->
    %% 更新所有消费者的 RDY
    NewConsumers = update_consumers_rdy(State#state.consumers, Count),
    {noreply, State#state{consumers = NewConsumers}};

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({'DOWN', _Ref, process, Pid, _Reason}, State) ->
    %% 消费者退出，从列表移除
    NewConsumers = lists:keydelete(Pid, #consumer.pid, State#state.consumers),

    %% 检查是否还有消费者（临时 Channel 无消费者时关闭）
    case State#state.ephemeral andalso NewConsumers == [] of
        true ->
            {stop, normal, State#state{consumers = NewConsumers}};
        false ->
            {noreply, State#state{consumers = NewConsumers}}
    end;

handle_info({deferred_requeue, _MsgId}, State) ->
    %% 延迟重新入队处理
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    logger:info("Channel ~s/~s stopped", [State#state.topic_name, State#state.channel_name]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =============================================================================
%% Internal functions
%% =============================================================================

%% 尝试投递消息给有 RDY 的消费者
try_deliver_messages(State) ->
    case queue:out(State#state.message_queue) of
        {empty, _} ->
            {noreply, State};
        {{value, Msg}, NewQueue} ->
            case find_ready_consumer(State#state.consumers) of
                undefined ->
                    %% 没有就绪的消费者，消息保留在队列
                    {noreply, State};
                Consumer ->
                    %% 投递消息
                    deliver_to_consumer(Consumer, Msg),
                    %% 更新消费者状态
                    NewConsumers = update_consumer_after_deliver(
                        State#state.consumers, Consumer, Msg),
                    try_deliver_messages(State#state{
                        consumers = NewConsumers,
                        message_queue = NewQueue
                    })
            end
    end.

%% 查找有 RDY 的消费者
find_ready_consumer([]) -> undefined;
find_ready_consumer([C | _Rest]) when C#consumer.rdy > 0 -> C;
find_ready_consumer([_ | Rest]) -> find_ready_consumer(Rest).

%% 投递消息给消费者
deliver_to_consumer(Consumer, Msg) ->
    case code:which(erwind_connection) of
        non_existing -> ok;
        _ ->
            erwind_connection:deliver_message(Consumer#consumer.pid, Msg)
    end.

%% 更新消费者投递后的状态
update_consumer_after_deliver(Consumers, Consumer, Msg) ->
    lists:map(fun(C) when C#consumer.pid == Consumer#consumer.pid ->
        NewInFlight = maps:put(Msg#nsq_message.id, Msg, C#consumer.inflight_msgs),
        C#consumer{
            rdy = C#consumer.rdy - 1,
            inflight_msgs = NewInFlight
        };
       (C) -> C
    end, Consumers).

%% 辅助函数：从所有消费者的 in_flight 中移除指定消息
-spec remove_from_inflight([#consumer{}], binary()) -> [#consumer{}].
remove_from_inflight(Consumers, MsgId) ->
    [C#consumer{inflight_msgs = maps:remove(MsgId, C#consumer.inflight_msgs)} || C <- Consumers].

%% 辅助函数：标记消息为重新入队
-spec mark_for_requeue([#consumer{}], binary(), integer(), pid()) -> [#consumer{}].
mark_for_requeue(Consumers, MsgId, Timeout, ChannelPid) ->
    [case maps:is_key(MsgId, C#consumer.inflight_msgs) of
        true ->
            erlang:send_after(Timeout, ChannelPid, {deferred_requeue, MsgId}),
            C;
        false ->
            C
    end || C <- Consumers].

%% 辅助函数：更新 in_flight 消息的超时时间
-spec touch_inflight_msgs([#consumer{}], binary()) -> [#consumer{}].
touch_inflight_msgs(Consumers, MsgId) ->
    [case maps:get(MsgId, C#consumer.inflight_msgs, undefined) of
        undefined -> C;
        Msg ->
            C#consumer{inflight_msgs = maps:put(MsgId, Msg, C#consumer.inflight_msgs)}
    end || C <- Consumers].

%% 辅助函数：更新所有消费者的 RDY
-spec update_consumers_rdy([#consumer{}], integer()) -> [#consumer{}].
update_consumers_rdy(Consumers, Count) ->
    [C#consumer{rdy = Count} || C <- Consumers].

%% 判断是否为临时 Channel
is_ephemeral(ChannelName) ->
    binary:longest_common_suffix([ChannelName, <<"#ephemeral">>]) == 10.
