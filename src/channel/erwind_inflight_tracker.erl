%% erwind_inflight_tracker.erl
%% 在途消息跟踪模块 - 跟踪已投递但未确认的消息

-module(erwind_inflight_tracker).
-behaviour(gen_server).

%% API
-export([start_link/2, track/5, ack/2, requeue/2, get/2,
         get_by_consumer/2, get_all/1, count/1, touch/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include_lib("erwind/include/erwind.hrl").

-record(inflight_entry, {
    msg :: #nsq_message{},
    consumer_pid :: pid(),
    deliver_time :: integer(),
    expire_time :: integer()
}).

-record(state, {
    topic :: binary(),
    channel :: binary(),
    messages = #{} :: #{binary() => #inflight_entry{}},
    by_consumer = #{} :: #{pid() => [binary()]},
    check_interval = 5000 :: non_neg_integer(),
    timer_ref :: reference() | undefined
}).

-define(DEFAULT_CHECK_INTERVAL, 5000).

%% =============================================================================
%% API
%% =============================================================================

-spec start_link(binary(), binary()) -> gen_server:start_ret().
start_link(Topic, Channel) when is_binary(Topic), is_binary(Channel) ->
    gen_server:start_link(?MODULE, [Topic, Channel], []).

-spec track(pid(), binary(), #nsq_message{}, pid(), integer()) -> ok.
track(Pid, MsgId, Msg, ConsumerPid, Timeout) when is_pid(Pid), is_binary(MsgId),
                                                   is_record(Msg, nsq_message),
                                                   is_pid(ConsumerPid), is_integer(Timeout) ->
    gen_server:cast(Pid, {track, MsgId, Msg, ConsumerPid, Timeout}).

-spec ack(pid(), binary()) -> ok | {error, not_found}.
ack(Pid, MsgId) when is_pid(Pid), is_binary(MsgId) ->
    case gen_server:call(Pid, {ack, MsgId}) of
        ok -> ok;
        {error, not_found} -> {error, not_found}
    end.

-spec requeue(pid(), binary()) -> {ok, #nsq_message{}} | {error, not_found}.
requeue(Pid, MsgId) when is_pid(Pid), is_binary(MsgId) ->
    case gen_server:call(Pid, {requeue, MsgId}) of
        {ok, Msg} when is_record(Msg, nsq_message) -> {ok, Msg};
        {error, not_found} -> {error, not_found}
    end.

-spec get(pid(), binary()) -> {ok, #inflight_entry{}} | {error, not_found}.
get(Pid, MsgId) when is_pid(Pid), is_binary(MsgId) ->
    case gen_server:call(Pid, {get, MsgId}) of
        {ok, Entry} when is_record(Entry, inflight_entry) -> {ok, Entry};
        {error, not_found} -> {error, not_found}
    end.

-spec get_by_consumer(pid(), pid()) -> [#nsq_message{}].
get_by_consumer(Pid, ConsumerPid) when is_pid(Pid), is_pid(ConsumerPid) ->
    Result = gen_server:call(Pid, {get_by_consumer, ConsumerPid}),
    true = is_list(Result),
    [M || M <- Result, is_record(M, nsq_message)].

-spec get_all(pid()) -> [#inflight_entry{}].
get_all(Pid) when is_pid(Pid) ->
    Result = gen_server:call(Pid, get_all),
    true = is_list(Result),
    [E || E <- Result, is_record(E, inflight_entry)].

-spec count(pid()) -> non_neg_integer().
count(Pid) when is_pid(Pid) ->
    Result = gen_server:call(Pid, count),
    true = is_integer(Result),
    Result.

-spec touch(pid(), binary()) -> ok | {error, not_found}.
touch(Pid, MsgId) when is_pid(Pid), is_binary(MsgId) ->
    case gen_server:call(Pid, {touch, MsgId}) of
        ok -> ok;
        {error, not_found} -> {error, not_found}
    end.

%% =============================================================================
%% gen_server callbacks
%% =============================================================================

init([Topic, Channel]) ->
    process_flag(trap_exit, true),
    TimerRef = erlang:send_after(?DEFAULT_CHECK_INTERVAL, self(), check_timeouts),
    {ok, #state{
        topic = Topic,
        channel = Channel,
        timer_ref = TimerRef
    }}.

handle_call({ack, MsgId}, _From, State) ->
    case do_remove(MsgId, State) of
        {ok, Entry, NewState} ->
            _ = Entry,
            {reply, ok, NewState};
        {error, not_found} ->
            {reply, {error, not_found}, State}
    end;

handle_call({requeue, MsgId}, _From, State) ->
    case do_remove(MsgId, State) of
        {ok, Entry, NewState} ->
            {reply, {ok, Entry#inflight_entry.msg}, NewState};
        {error, not_found} ->
            {reply, {error, not_found}, State}
    end;

handle_call({get, MsgId}, _From, State) ->
    case maps:get(MsgId, State#state.messages, undefined) of
        undefined -> {reply, {error, not_found}, State};
        Entry -> {reply, {ok, Entry}, State}
    end;

handle_call({get_by_consumer, ConsumerPid}, _From, State) ->
    MsgIds = maps:get(ConsumerPid, State#state.by_consumer, []),
    Msgs = [begin
        Entry = maps:get(MsgId, State#state.messages),
        Entry#inflight_entry.msg
    end || MsgId <- MsgIds, maps:is_key(MsgId, State#state.messages)],
    {reply, Msgs, State};

handle_call(get_all, _From, State) ->
    Entries = maps:values(State#state.messages),
    {reply, Entries, State};

handle_call(count, _From, State) ->
    {reply, map_size(State#state.messages), State};

handle_call({touch, MsgId}, _From, State) ->
    case maps:get(MsgId, State#state.messages, undefined) of
        undefined ->
            {reply, {error, not_found}, State};
        Entry ->
            Now = erlang:system_time(millisecond),
            Timeout = Entry#inflight_entry.expire_time - Entry#inflight_entry.deliver_time,
            NewEntry = Entry#inflight_entry{
                deliver_time = Now,
                expire_time = Now + Timeout
            },
            NewMessages = maps:put(MsgId, NewEntry, State#state.messages),
            {reply, ok, State#state{messages = NewMessages}}
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({track, MsgId, Msg, ConsumerPid, Timeout}, State) when is_binary(MsgId), is_record(Msg, nsq_message), is_pid(ConsumerPid), is_integer(Timeout) ->
    Now = erlang:system_time(millisecond),
    Entry = #inflight_entry{
        msg = Msg,
        consumer_pid = ConsumerPid,
        deliver_time = Now,
        expire_time = Now + Timeout
    },
    NewMessages = maps:put(MsgId, Entry, State#state.messages),
    ConsumerMsgs = maps:get(ConsumerPid, State#state.by_consumer, []),
    NewByConsumer = maps:put(ConsumerPid, [MsgId | ConsumerMsgs], State#state.by_consumer),
    {noreply, State#state{messages = NewMessages, by_consumer = NewByConsumer}};

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(check_timeouts, State) when is_record(State, state) ->
    Now = erlang:system_time(millisecond),
    Expired = find_expired(State#state.messages, Now, []),
    %% Notify channel about expired messages
    lists:foreach(fun({_MsgId, Entry}) when is_record(Entry, inflight_entry) ->
        ChannelPid = get_channel_pid(),
        case ChannelPid of
            undefined -> ok;
            _ -> ChannelPid ! {timeout, Entry#inflight_entry.msg}
        end;
       (_) -> ok
    end, Expired),
    %% Remove expired from state
    ResultState = lists:foldl(
        fun({MsgId, _}, AccState) when is_record(AccState, state), is_binary(MsgId) ->
            case do_remove(MsgId, AccState) of
                {ok, _, NS} when is_record(NS, state) -> NS;
                {error, _} -> AccState
            end;
           (_, AccState) -> AccState
        end, State, Expired),
    %% Ensure result is a valid state
    NewState = case ResultState of
        S when is_record(S, state) -> S;
        _ -> State
    end,
    %% Reschedule timer
    NewTimer = erlang:send_after(State#state.check_interval, self(), check_timeouts),
    {noreply, NewState#state{timer_ref = NewTimer}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =============================================================================
%% Internal functions
%% =============================================================================

-spec do_remove(binary(), #state{}) -> {ok, #inflight_entry{}, #state{}} | {error, not_found}.
do_remove(MsgId, State) ->
    case maps:get(MsgId, State#state.messages, undefined) of
        undefined ->
            {error, not_found};
        Entry when is_record(Entry, inflight_entry) ->
            NewMessages = maps:remove(MsgId, State#state.messages),
            ConsumerPid = Entry#inflight_entry.consumer_pid,
            ConsumerMsgs = maps:get(ConsumerPid, State#state.by_consumer, []),
            NewConsumerMsgs = [M || M <- ConsumerMsgs, is_binary(M)],
            NewByConsumer = case NewConsumerMsgs of
                [] -> maps:remove(ConsumerPid, State#state.by_consumer);
                _ -> maps:put(ConsumerPid, NewConsumerMsgs, State#state.by_consumer)
            end,
            {ok, Entry, State#state{messages = NewMessages, by_consumer = NewByConsumer}}
    end.

-spec find_expired(#{binary() => #inflight_entry{}}, integer(), [{binary(), #inflight_entry{}}]) -> [{binary(), #inflight_entry{}}].
find_expired(_Messages, _Now, Acc) ->
    %% Simplified - in production would actually check expirations
    Acc.

get_channel_pid() ->
    %% In production, would track the channel pid
    undefined.
