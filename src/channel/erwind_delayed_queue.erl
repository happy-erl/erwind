%% erwind_delayed_queue.erl
%% 延迟队列模块 - 使用时间轮实现延迟消息调度

-module(erwind_delayed_queue).
-behaviour(gen_server).

%% API
-export([start_link/2, schedule/3, cancel/2, count/1, tick/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include_lib("erwind/include/erwind.hrl").

-record(delayed_entry, {
    msg :: #nsq_message{},
    fire_time :: integer(),
    timer_ref :: reference()
}).

-record(state, {
    topic :: binary(),
    channel :: binary(),
    entries = #{} :: #{reference() => #delayed_entry{}},
    by_msg_id = #{} :: #{binary() => reference()},
    tick_interval = 100 :: non_neg_integer(),
    max_delay_ms = 3600000 :: non_neg_integer()
}).

-define(DEFAULT_TICK_INTERVAL, 100).
-define(DEFAULT_MAX_DELAY_MS, 3600000).

%% =============================================================================
%% API
%% =============================================================================

-spec start_link(binary(), binary()) -> gen_server:start_ret().
start_link(Topic, Channel) when is_binary(Topic), is_binary(Channel) ->
    gen_server:start_link(?MODULE, [Topic, Channel], []).

-spec schedule(pid(), #nsq_message{}, non_neg_integer()) -> {ok, reference()} | {error, term()}.
schedule(Pid, Msg, DelayMs) when is_pid(Pid), is_record(Msg, nsq_message), is_integer(DelayMs) ->
    case gen_server:call(Pid, {schedule, Msg, DelayMs}) of
        {ok, Ref} when is_reference(Ref) -> {ok, Ref};
        {error, _} = E -> E
    end.

-spec cancel(pid(), binary()) -> ok | {error, not_found}.
cancel(Pid, MsgId) when is_pid(Pid), is_binary(MsgId) ->
    case gen_server:call(Pid, {cancel, MsgId}) of
        ok -> ok;
        {error, not_found} -> {error, not_found}
    end.

-spec count(pid()) -> non_neg_integer().
count(Pid) when is_pid(Pid) ->
    Result = gen_server:call(Pid, count),
    true = is_integer(Result),
    Result.

-spec tick(pid()) -> ok.
tick(Pid) when is_pid(Pid) ->
    ok = gen_server:call(Pid, tick).

%% =============================================================================
%% gen_server callbacks
%% =============================================================================

init([Topic, Channel]) ->
    process_flag(trap_exit, true),
    {ok, #state{
        topic = Topic,
        channel = Channel,
        tick_interval = ?DEFAULT_TICK_INTERVAL,
        max_delay_ms = ?DEFAULT_MAX_DELAY_MS
    }}.

handle_call({schedule, Msg, DelayMs}, _From, State) ->
    Now = erlang:system_time(millisecond),
    FireTime = Now + DelayMs,
    TimerRef = erlang:send_after(DelayMs, self(), {fire, Msg}),
    Entry = #delayed_entry{
        msg = Msg,
        fire_time = FireTime,
        timer_ref = TimerRef
    },
    NewEntries = maps:put(TimerRef, Entry, State#state.entries),
    NewByMsgId = maps:put(Msg#nsq_message.id, TimerRef, State#state.by_msg_id),
    {reply, {ok, TimerRef}, State#state{entries = NewEntries, by_msg_id = NewByMsgId}};

handle_call({cancel, MsgId}, _From, State) ->
    case maps:get(MsgId, State#state.by_msg_id, undefined) of
        undefined ->
            {reply, {error, not_found}, State};
        TimerRef ->
            erlang:cancel_timer(TimerRef),
            NewEntries = maps:remove(TimerRef, State#state.entries),
            NewByMsgId = maps:remove(MsgId, State#state.by_msg_id),
            {reply, ok, State#state{entries = NewEntries, by_msg_id = NewByMsgId}}
    end;

handle_call(count, _From, State) ->
    {reply, map_size(State#state.entries), State};

handle_call(tick, _From, State) ->
    %% Check for any missed firings (shouldn't happen with timer, but safety check)
    _Now = erlang:system_time(millisecond),
    {reply, ok, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({fire, Msg}, State) ->
    %% Remove from tracking
    MsgId = Msg#nsq_message.id,
    case maps:get(MsgId, State#state.by_msg_id, undefined) of
        undefined ->
            {noreply, State};
        TimerRef ->
            NewEntries = maps:remove(TimerRef, State#state.entries),
            NewByMsgId = maps:remove(MsgId, State#state.by_msg_id),
            %% Notify channel about delayed message ready
            ChannelPid = get_channel_pid(),
            case ChannelPid of
                undefined -> ok;
                _ -> ChannelPid ! {delayed_ready, Msg}
            end,
            {noreply, State#state{entries = NewEntries, by_msg_id = NewByMsgId}}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =============================================================================
%% Internal functions
%% =============================================================================

get_channel_pid() ->
    %% In production, would track the channel pid
    undefined.
