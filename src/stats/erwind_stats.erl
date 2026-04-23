%% erwind_stats.erl
%% Statistics module for collecting and aggregating system metrics

-module(erwind_stats).
-behaviour(gen_server).

%% API - Core operations
-export([start_link/0, stop/0]).
-export([incr/2, decr/2, gauge/2, timing/2]).
-export([incr_topic/2, incr_channel/3, incr_consumer/2]).
-export([decr_topic/2, decr_channel/3, decr_consumer/2]).
-export([gauge_topic/3, gauge_channel/4, gauge_consumer/3, gauge_global/2]).

%% API - Stats retrieval
-export([get_topic_stats/1, get_channel_stats/2, get_consumer_stats/1, get_global_stats/0]).
-export([get_all_topic_stats/0, get_all_channel_stats/0]).
-export([get_start_time/0, get_uptime/0]).

%% API - Export
-export([reset_stats/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include_lib("erwind/include/erwind.hrl").

%% ETS table names
-define(TOPIC_STATS, erwind_topic_stats).
-define(CHANNEL_STATS, erwind_channel_stats).
-define(CONSUMER_STATS, erwind_consumer_stats).
-define(GLOBAL_STATS, erwind_global_stats).
-define(EWMA_STATE, erwind_ewma_state).

%% EWMA alpha constants for rate calculation
-define(ALPHA_1M, 0.0799555853706767).
-define(ALPHA_5M, 0.0191988897560153).
-define(ALPHA_15M, 0.00652986989124683).

%% Rate calculation interval (ms)
-define(RATE_INTERVAL, 1000).

%% State record
-record(state, {
    start_time :: integer(),
    rate_interval :: integer()
}).

%% =============================================================================
%% API - Start/Stop
%% =============================================================================

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec stop() -> ok.
stop() ->
    gen_server:stop(?MODULE).

%% =============================================================================
%% API - Generic Counter Operations
%% =============================================================================

%% Increment a counter by 1
-spec incr(Type :: atom(), Key :: term()) -> integer().
incr(Type, Key) ->
    do_incr(Type, Key, 1).

%% Decrement a counter by 1
-spec decr(Type :: atom(), Key :: term()) -> integer().
decr(Type, Key) ->
    do_incr(Type, Key, -1).

%% Set a gauge value
-spec gauge(Type :: atom(), KeyValue :: term()) -> ok.
gauge(topic, {Topic, Key, Value}) when is_binary(Topic), is_atom(Key) ->
    gauge_topic(Topic, Key, Value);
gauge(channel, {Topic, Channel, Key, Value}) when is_binary(Topic), is_binary(Channel), is_atom(Key) ->
    gauge_channel(Topic, Channel, Key, Value);
gauge(consumer, {Pid, Key, Value}) when is_pid(Pid), is_atom(Key) ->
    gauge_consumer(Pid, Key, Value);
gauge(global, {Key, Value}) when is_atom(Key) ->
    gauge_global(Key, Value).

%% Record a timing value (stores as gauge)
-spec timing(Key :: term(), Time :: integer()) -> ok.
timing(Key, Time) when is_integer(Time) ->
    gauge_global({timing, Key}, Time).

%% =============================================================================
%% API - Topic Stats
%% =============================================================================

-spec incr_topic(Topic :: binary(), Key :: atom()) -> integer().
incr_topic(Topic, Key) ->
    do_incr(topic, {Topic, Key}, 1).

-spec decr_topic(Topic :: binary(), Key :: atom()) -> integer().
decr_topic(Topic, Key) ->
    do_incr(topic, {Topic, Key}, -1).

-spec gauge_topic(Topic :: binary(), Key :: atom(), Value :: term()) -> ok.
gauge_topic(Topic, Key, Value) ->
    ets:insert(?TOPIC_STATS, {{Topic, Key}, Value}),
    ok.

-spec get_topic_stats(Topic :: binary()) -> map().
get_topic_stats(Topic) ->
    #{
        topic => Topic,
        message_count => get_counter(?TOPIC_STATS, {Topic, message_count}),
        depth => get_counter(?TOPIC_STATS, {Topic, depth}),
        backend_depth => get_counter(?TOPIC_STATS, {Topic, backend_depth}),
        paused => get_gauge(?TOPIC_STATS, {Topic, paused}, false),
        message_rate_1m => get_ewma({topic, Topic, rate_1m}),
        message_rate_5m => get_ewma({topic, Topic, rate_5m}),
        message_rate_15m => get_ewma({topic, Topic, rate_15m})
    }.

%% =============================================================================
%% API - Channel Stats
%% =============================================================================

-spec incr_channel(Topic :: binary(), Channel :: binary(), Key :: atom()) -> integer().
incr_channel(Topic, Channel, Key) ->
    do_incr(channel, {Topic, Channel, Key}, 1).

-spec decr_channel(Topic :: binary(), Channel :: binary(), Key :: atom()) -> integer().
decr_channel(Topic, Channel, Key) ->
    do_incr(channel, {Topic, Channel, Key}, -1).

-spec gauge_channel(Topic :: binary(), Channel :: binary(), Key :: atom(), Value :: term()) -> ok.
gauge_channel(Topic, Channel, Key, Value) ->
    ets:insert(?CHANNEL_STATS, {{Topic, Channel, Key}, Value}),
    ok.

-spec get_channel_stats(Topic :: binary(), Channel :: binary()) -> map().
get_channel_stats(Topic, Channel) ->
    #{
        topic => Topic,
        channel => Channel,
        depth => get_counter(?CHANNEL_STATS, {Topic, Channel, depth}),
        in_flight_count => get_counter(?CHANNEL_STATS, {Topic, Channel, in_flight_count}),
        deferred_count => get_counter(?CHANNEL_STATS, {Topic, Channel, deferred_count}),
        message_count => get_counter(?CHANNEL_STATS, {Topic, Channel, message_count}),
        requeue_count => get_counter(?CHANNEL_STATS, {Topic, Channel, requeue_count}),
        timeout_count => get_counter(?CHANNEL_STATS, {Topic, Channel, timeout_count}),
        consumer_count => get_counter(?CHANNEL_STATS, {Topic, Channel, consumer_count})
    }.

%% =============================================================================
%% API - Consumer Stats
%% =============================================================================

-spec incr_consumer(Pid :: pid(), Key :: atom()) -> integer().
incr_consumer(Pid, Key) ->
    do_incr(consumer, {Pid, Key}, 1).

-spec decr_consumer(Pid :: pid(), Key :: atom()) -> integer().
decr_consumer(Pid, Key) ->
    do_incr(consumer, {Pid, Key}, -1).

-spec gauge_consumer(Pid :: pid(), Key :: atom(), Value :: term()) -> ok.
gauge_consumer(Pid, Key, Value) ->
    ets:insert(?CONSUMER_STATS, {{Pid, Key}, Value}),
    ok.

-spec get_consumer_stats(Pid :: pid()) -> map().
get_consumer_stats(Pid) ->
    #{
        pid => Pid,
        rdy_count => get_counter(?CONSUMER_STATS, {Pid, rdy_count}),
        in_flight_count => get_counter(?CONSUMER_STATS, {Pid, in_flight_count}),
        finish_count => get_counter(?CONSUMER_STATS, {Pid, finish_count}),
        requeue_count => get_counter(?CONSUMER_STATS, {Pid, requeue_count}),
        connect_time => get_gauge(?CONSUMER_STATS, {Pid, connect_time}, 0)
    }.

%% =============================================================================
%% API - Global Stats
%% =============================================================================

-spec gauge_global(Key :: atom() | {atom(), term()}, Value :: term()) -> ok.
gauge_global(Key, Value) ->
    ets:insert(?GLOBAL_STATS, {Key, Value}),
    ok.

-spec get_global_stats() -> map().
get_global_stats() ->
    StartTime = get_start_time(),
    Uptime = erlang:system_time(millisecond) - StartTime,
    #{
        start_time => StartTime,
        uptime => Uptime,
        uptime_seconds => Uptime div 1000,
        total_messages => get_counter(?GLOBAL_STATS, total_messages),
        total_topics => count_unique_keys(?TOPIC_STATS, 1),
        total_channels => count_unique_keys(?CHANNEL_STATS, 2),
        memory_bytes => erlang:memory(total),
        version => get_app_version()
    }.

-spec get_start_time() -> integer().
get_start_time() ->
    case ets:lookup(?GLOBAL_STATS, start_time) of
        [{start_time, Time}] -> Time;
        [] -> 0
    end.

-spec get_uptime() -> integer().
get_uptime() ->
    erlang:system_time(millisecond) - get_start_time().

-spec get_all_topic_stats() -> [map()].
get_all_topic_stats() ->
    Topics = get_unique_topics(),
    [get_topic_stats(Topic) || Topic <- Topics].

-spec get_all_channel_stats() -> [map()].
get_all_channel_stats() ->
    Channels = get_unique_channels(),
    [get_channel_stats(Topic, Channel) || {Topic, Channel} <- Channels].

-spec reset_stats() -> ok.
reset_stats() ->
    gen_server:call(?MODULE, reset_stats).

%% =============================================================================
%% Internal Functions - Counter Operations
%% =============================================================================

do_incr(topic, {Topic, Key}, Incr) ->
    ets:update_counter(?TOPIC_STATS, {Topic, Key}, {2, Incr}, {{Topic, Key}, 0});
do_incr(channel, {Topic, Channel, Key}, Incr) ->
    ets:update_counter(?CHANNEL_STATS, {Topic, Channel, Key}, {2, Incr}, {{Topic, Channel, Key}, 0});
do_incr(consumer, {Pid, Key}, Incr) ->
    ets:update_counter(?CONSUMER_STATS, {Pid, Key}, {2, Incr}, {{Pid, Key}, 0});
do_incr(global, Key, Incr) ->
    ets:update_counter(?GLOBAL_STATS, Key, {2, Incr}, {Key, 0}).

get_counter(Table, Key) ->
    try ets:lookup_element(Table, Key, 2) of
        Value when is_integer(Value) -> Value;
        Value when is_float(Value) -> trunc(Value)
    catch
        error:badarg -> 0
    end.

get_gauge(Table, Key, Default) ->
    try ets:lookup_element(Table, Key, 2) of
        Value -> Value
    catch
        error:badarg -> Default
    end.

%% =============================================================================
%% Internal Functions - EWMA Rate Calculation
%% =============================================================================

get_ewma(Key) ->
    case ets:lookup(?EWMA_STATE, Key) of
        [{_, Rate}] -> Rate;
        [] -> 0.0
    end.

update_ewma(Key, Delta, Alpha) ->
    CurrentRate = get_ewma(Key),
    NewRate = CurrentRate + Alpha * (Delta - CurrentRate),
    ets:insert(?EWMA_STATE, {Key, NewRate}),
    NewRate.

calculate_rates() ->
    %% Calculate topic rates
    Topics = get_unique_topics(),
    lists:foreach(fun calculate_topic_rates/1, Topics),

    %% Calculate channel rates
    Channels = get_unique_channels(),
    lists:foreach(fun({Topic, Channel}) ->
        calculate_channel_rates(Topic, Channel)
    end, Channels).

calculate_topic_rates(Topic) ->
    CurrentCount = get_counter(?TOPIC_STATS, {Topic, message_count}),
    PrevCount = get_counter(?TOPIC_STATS, {Topic, message_count_prev}),
    Delta = CurrentCount - PrevCount,

    %% Update EWMA rates
    update_ewma({topic, Topic, rate_1m}, max(0, Delta), ?ALPHA_1M),
    update_ewma({topic, Topic, rate_5m}, max(0, Delta), ?ALPHA_5M),
    update_ewma({topic, Topic, rate_15m}, max(0, Delta), ?ALPHA_15M),

    %% Store current count as previous
    ets:insert(?TOPIC_STATS, {{Topic, message_count_prev}, CurrentCount}).

calculate_channel_rates(Topic, Channel) ->
    CurrentCount = get_counter(?CHANNEL_STATS, {Topic, Channel, message_count}),
    PrevCount = get_counter(?CHANNEL_STATS, {Topic, Channel, message_count_prev}),
    Delta = CurrentCount - PrevCount,

    %% Update EWMA rates
    update_ewma({channel, Topic, Channel, rate_1m}, max(0, Delta), ?ALPHA_1M),
    update_ewma({channel, Topic, Channel, rate_5m}, max(0, Delta), ?ALPHA_5M),
    update_ewma({channel, Topic, Channel, rate_15m}, max(0, Delta), ?ALPHA_15M),

    %% Store current count as previous
    ets:insert(?CHANNEL_STATS, {{Topic, Channel, message_count_prev}, CurrentCount}).

%% =============================================================================
%% Internal Functions - Utility
%% =============================================================================

get_unique_topics() ->
    lists:usort([Topic || [Topic] <- ets:match(?TOPIC_STATS, {{'$1', '_'}, '_'})]).

get_unique_channels() ->
    lists:usort([{Topic, Channel} || [Topic, Channel] <- ets:match(?CHANNEL_STATS, {{'$1', '$2', '_'}, '_'})]).

count_unique_keys(Table, _Pos) ->
    %% Use ets:fold to count unique first elements of keys
    UniqueSet = ets:foldl(
        fun({{First, _}, _}, Acc) ->
                sets:add_element(First, Acc);
           (_, Acc) ->
                Acc
        end,
        sets:new(),
        Table
    ),
    sets:size(UniqueSet).

get_app_version() ->
    case application:get_key(erwind, vsn) of
        {ok, Vsn} -> list_to_binary(Vsn);
        undefined -> <<"0.1.0">>
    end.

%% =============================================================================
%% gen_server callbacks
%% =============================================================================

init([]) ->
    %% Create ETS tables with public access for concurrent reads
    ets:new(?TOPIC_STATS, [set, named_table, public, {read_concurrency, true}]),
    ets:new(?CHANNEL_STATS, [set, named_table, public, {read_concurrency, true}]),
    ets:new(?CONSUMER_STATS, [set, named_table, public, {read_concurrency, true}]),
    ets:new(?GLOBAL_STATS, [set, named_table, public, {read_concurrency, true}]),
    ets:new(?EWMA_STATE, [set, named_table, public, {read_concurrency, true}]),

    %% Set start time
    StartTime = erlang:system_time(millisecond),
    ets:insert(?GLOBAL_STATS, {start_time, StartTime}),

    %% Start rate calculation timer
    erlang:send_after(?RATE_INTERVAL, self(), calculate_rates),

    {ok, #state{start_time = StartTime, rate_interval = ?RATE_INTERVAL}}.

handle_call(reset_stats, _From, State) ->
    %% Clear all stats except start_time
    StartTime = State#state.start_time,
    ets:delete_all_objects(?TOPIC_STATS),
    ets:delete_all_objects(?CHANNEL_STATS),
    ets:delete_all_objects(?CONSUMER_STATS),
    ets:delete_all_objects(?EWMA_STATE),
    ets:delete_all_objects(?GLOBAL_STATS),
    ets:insert(?GLOBAL_STATS, {start_time, StartTime}),
    {reply, ok, State};

handle_call({get_topic_stats, Topic}, _From, State) ->
    Stats = get_topic_stats(Topic),
    {reply, {ok, Stats}, State};

handle_call({get_channel_stats, Topic, Channel}, _From, State) ->
    Stats = get_channel_stats(Topic, Channel),
    {reply, {ok, Stats}, State};

handle_call(get_global_stats, _From, State) ->
    Stats = get_global_stats(),
    {reply, {ok, Stats}, State};

handle_call(get_start_time, _From, State) ->
    {reply, State#state.start_time, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(calculate_rates, State) ->
    calculate_rates(),
    erlang:send_after(State#state.rate_interval, self(), calculate_rates),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    %% Clean up ETS tables
    ets:delete(?TOPIC_STATS),
    ets:delete(?CHANNEL_STATS),
    ets:delete(?CONSUMER_STATS),
    ets:delete(?GLOBAL_STATS),
    ets:delete(?EWMA_STATE),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
