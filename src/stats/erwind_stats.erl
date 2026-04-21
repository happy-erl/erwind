%% erwind_stats.erl
%% 统计模块桩 - 消息统计
%% TODO: 完整实现需要添加统计收集和聚合逻辑

-module(erwind_stats).

%% API
-export([start_link/0, incr_topic_msg_count/1, incr_channel_msg_count/2,
         get_topic_stats/1, get_channel_stats/2, get_global_stats/0, get_start_time/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include_lib("erwind/include/erwind.hrl").

-record(state, {
    topic_counts = #{} :: map(),
    channel_counts = #{} :: map(),
    start_time = erlang:system_time(millisecond) :: integer()
}).

%% =============================================================================
%% API
%% =============================================================================

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec incr_topic_msg_count(binary()) -> ok.
incr_topic_msg_count(TopicName) when is_binary(TopicName) ->
    gen_server:cast(?MODULE, {incr_topic, TopicName}).

-spec incr_channel_msg_count(binary(), binary()) -> ok.
incr_channel_msg_count(TopicName, ChannelName) when is_binary(TopicName), is_binary(ChannelName) ->
    gen_server:cast(?MODULE, {incr_channel, TopicName, ChannelName}).

-spec get_topic_stats(binary()) -> map().
get_topic_stats(TopicName) when is_binary(TopicName) ->
    Result = gen_server:call(?MODULE, {get_topic_stats, TopicName}),
    %% Type guard for eqwalizer
    true = is_map(Result),
    Result.

-spec get_channel_stats(binary(), binary()) -> map().
get_channel_stats(TopicName, ChannelName) when is_binary(TopicName), is_binary(ChannelName) ->
    Result = gen_server:call(?MODULE, {get_channel_stats, TopicName, ChannelName}),
    %% Type guard for eqwalizer
    true = is_map(Result),
    Result.

-spec get_global_stats() -> map().
get_global_stats() ->
    Result = gen_server:call(?MODULE, get_global_stats),
    %% Type guard for eqwalizer
    true = is_map(Result),
    Result.

-spec get_start_time() -> integer().
get_start_time() ->
    Result = gen_server:call(?MODULE, get_start_time),
    %% Type guard for eqwalizer
    true = is_integer(Result),
    Result.

%% =============================================================================
%% gen_server callbacks
%% =============================================================================

init([]) ->
    {ok, #state{}}.

handle_call({get_topic_stats, TopicName}, _From, State) ->
    Count = maps:get(TopicName, State#state.topic_counts, 0),
    {reply, #{message_count => Count}, State};

handle_call({get_channel_stats, TopicName, ChannelName}, _From, State) ->
    Count = maps:get({TopicName, ChannelName}, State#state.channel_counts, 0),
    {reply, #{message_count => Count}, State};

handle_call(get_global_stats, _From, State) ->
    Total = lists:sum(maps:values(State#state.topic_counts)),
    {reply, #{total_messages => Total}, State};

handle_call(get_start_time, _From, State) ->
    {reply, State#state.start_time, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({incr_topic, TopicName}, State) ->
    Count = maps:get(TopicName, State#state.topic_counts, 0),
    NewCounts = maps:put(TopicName, Count + 1, State#state.topic_counts),
    {noreply, State#state{topic_counts = NewCounts}};

handle_cast({incr_channel, TopicName, ChannelName}, State) ->
    Key = {TopicName, ChannelName},
    Count = maps:get(Key, State#state.channel_counts, 0),
    NewCounts = maps:put(Key, Count + 1, State#state.channel_counts),
    {noreply, State#state{channel_counts = NewCounts}};

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
