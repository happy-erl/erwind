%% erwind_consumer_manager.erl
%% 消费者管理模块 - 负责消费者注册、RDY 管理和负载均衡

-module(erwind_consumer_manager).
-behaviour(gen_server).

%% API
-export([start_link/2, stop/1, register_consumer/2, unregister_consumer/2,
         update_rdy/3, select_consumer/1, get_consumers/1,
         incr_inflight/2, decr_inflight/2, get_stats/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include_lib("erwind/include/erwind.hrl").

-record(state, {
    topic :: binary(),
    channel :: binary(),
    consumers = #{} :: #{pid() => #consumer{}},
    balance_strategy = round_robin :: round_robin | random,
    last_selected :: pid() | undefined
}).

%% =============================================================================
%% API
%% =============================================================================

-spec start_link(binary(), binary()) -> gen_server:start_ret().
start_link(Topic, Channel) when is_binary(Topic), is_binary(Channel) ->
    gen_server:start_link(?MODULE, [Topic, Channel], []).

-spec stop(pid()) -> ok.
stop(Pid) when is_pid(Pid) ->
    gen_server:stop(Pid).

-spec register_consumer(pid(), pid()) -> ok | {error, term()}.
register_consumer(Pid, ConsumerPid) when is_pid(Pid), is_pid(ConsumerPid) ->
    Result = gen_server:call(Pid, {register, ConsumerPid}),
    case Result of
        ok -> ok;
        {error, _} = E -> E
    end.

-spec unregister_consumer(pid(), pid()) -> ok.
unregister_consumer(Pid, ConsumerPid) when is_pid(Pid), is_pid(ConsumerPid) ->
    ok = gen_server:call(Pid, {unregister, ConsumerPid}).

-spec update_rdy(pid(), pid(), integer()) -> ok.
update_rdy(Pid, ConsumerPid, Count) when is_pid(Pid), is_pid(ConsumerPid), is_integer(Count) ->
    gen_server:cast(Pid, {update_rdy, ConsumerPid, Count}).

-spec select_consumer(pid()) -> {ok, pid(), #consumer{}} | empty.
select_consumer(Pid) when is_pid(Pid) ->
    case gen_server:call(Pid, select_consumer) of
        {ok, ConsumerPid, Consumer} when is_pid(ConsumerPid), is_record(Consumer, consumer) ->
            {ok, ConsumerPid, Consumer};
        empty -> empty
    end.

-spec get_consumers(pid()) -> [pid()].
get_consumers(Pid) when is_pid(Pid) ->
    case gen_server:call(Pid, get_consumers) of
        List when is_list(List) -> [P || P <- List, is_pid(P)];
        _ -> []
    end.

-spec incr_inflight(pid(), pid()) -> ok.
incr_inflight(Pid, ConsumerPid) when is_pid(Pid), is_pid(ConsumerPid) ->
    gen_server:cast(Pid, {incr_inflight, ConsumerPid}).

-spec decr_inflight(pid(), pid()) -> ok.
decr_inflight(Pid, ConsumerPid) when is_pid(Pid), is_pid(ConsumerPid) ->
    gen_server:cast(Pid, {decr_inflight, ConsumerPid}).

-spec get_stats(pid()) -> map().
get_stats(Pid) when is_pid(Pid) ->
    Result = gen_server:call(Pid, get_stats),
    true = is_map(Result),
    Result.

%% =============================================================================
%% gen_server callbacks
%% =============================================================================

init([Topic, Channel]) ->
    process_flag(trap_exit, true),
    {ok, #state{topic = Topic, channel = Channel}}.

handle_call({register, ConsumerPid}, _From, State) ->
    case maps:is_key(ConsumerPid, State#state.consumers) of
        true ->
            {reply, {error, already_registered}, State};
        false ->
            erlang:monitor(process, ConsumerPid),
            Consumer = #consumer{pid = ConsumerPid, rdy = 1},
            NewConsumers = maps:put(ConsumerPid, Consumer, State#state.consumers),
            {reply, ok, State#state{consumers = NewConsumers}}
    end;

handle_call({unregister, ConsumerPid}, _From, State) ->
    NewConsumers = maps:remove(ConsumerPid, State#state.consumers),
    {reply, ok, State#state{consumers = NewConsumers}};

handle_call(select_consumer, _From, State) ->
    case select_ready_consumer(State) of
        {ok, Pid, Consumer} ->
            {reply, {ok, Pid, Consumer}, State};
        empty ->
            {reply, empty, State}
    end;

handle_call(get_consumers, _From, State) ->
    Pids = maps:keys(State#state.consumers),
    {reply, Pids, State};

handle_call(get_stats, _From, State) ->
    Stats = #{
        topic => State#state.topic,
        channel => State#state.channel,
        consumer_count => map_size(State#state.consumers),
        total_rdy => lists:sum([C#consumer.rdy || C <- maps:values(State#state.consumers)]),
        total_inflight => lists:sum([C#consumer.in_flight || C <- maps:values(State#state.consumers)])
    },
    {reply, Stats, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({update_rdy, ConsumerPid, Count}, State) ->
    NewConsumers = case maps:get(ConsumerPid, State#state.consumers, undefined) of
        undefined -> State#state.consumers;
        Consumer ->
            maps:put(ConsumerPid, Consumer#consumer{rdy = Count}, State#state.consumers)
    end,
    {noreply, State#state{consumers = NewConsumers}};

handle_cast({incr_inflight, ConsumerPid}, State) ->
    NewConsumers = case maps:get(ConsumerPid, State#state.consumers, undefined) of
        undefined -> State#state.consumers;
        Consumer ->
            maps:put(ConsumerPid, Consumer#consumer{
                rdy = Consumer#consumer.rdy - 1,
                in_flight = Consumer#consumer.in_flight + 1
            }, State#state.consumers)
    end,
    {noreply, State#state{consumers = NewConsumers}};

handle_cast({decr_inflight, ConsumerPid}, State) ->
    NewConsumers = case maps:get(ConsumerPid, State#state.consumers, undefined) of
        undefined -> State#state.consumers;
        Consumer ->
            maps:put(ConsumerPid, Consumer#consumer{
                in_flight = Consumer#consumer.in_flight - 1
            }, State#state.consumers)
    end,
    {noreply, State#state{consumers = NewConsumers}};

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({'DOWN', _Ref, process, Pid, _Reason}, State) ->
    NewConsumers = maps:remove(Pid, State#state.consumers),
    {noreply, State#state{consumers = NewConsumers}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =============================================================================
%% Internal functions
%% =============================================================================

select_ready_consumer(#state{consumers = Consumers, balance_strategy = round_robin} = State) ->
    ReadyConsumers = [{Pid, C} || {Pid, C} <- maps:to_list(Consumers), C#consumer.rdy > 0],
    case ReadyConsumers of
        [] -> empty;
        List ->
            %% Round-robin selection
            {Pid, Consumer} = select_next(List, State#state.last_selected),
            {ok, Pid, Consumer}
    end;
select_ready_consumer(#state{consumers = Consumers, balance_strategy = random}) ->
    ReadyConsumers = [{Pid, C} || {Pid, C} <- maps:to_list(Consumers), C#consumer.rdy > 0],
    case ReadyConsumers of
        [] -> empty;
        List ->
            {Pid, Consumer} = lists:nth(rand:uniform(length(List)), List),
            {ok, Pid, Consumer}
    end.

select_next([{Pid, Consumer} | _], undefined) ->
    {Pid, Consumer};
select_next(List, LastPid) ->
    case lists:keyfind(LastPid, 1, List) of
        false ->
            %% Last selected not in ready list, pick first
            {Pid, Consumer} = hd(List),
            {Pid, Consumer};
        _ ->
            %% Find next after last selected
            case lists:dropwhile(fun({P, _}) -> P =/= LastPid end, List) of
                [{_, _}, {Pid, Consumer} | _] -> {Pid, Consumer};
                _ -> hd(List)
            end
    end.
