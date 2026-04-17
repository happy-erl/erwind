%% erwind_lookupd.erl
%% NSQ Lookupd 客户端桩 - 服务注册发现
%% TODO: 完整实现需要与 nsqlookupd 服务通信

-module(erwind_lookupd).

%% API
-export([start_link/0, register_topic/1, unregister_topic/1,
         register_channel/2, unregister_channel/2, lookup/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("../include/erwind.hrl").

-record(state, {
    registered_topics = [] :: [binary()],
    registered_channels = [] :: [{binary(), binary()}]
}).

%% =============================================================================
%% API
%% =============================================================================

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec register_topic(binary()) -> ok.
register_topic(TopicName) when is_binary(TopicName) ->
    gen_server:cast(?MODULE, {register_topic, TopicName}).

-spec unregister_topic(binary()) -> ok.
unregister_topic(TopicName) when is_binary(TopicName) ->
    gen_server:cast(?MODULE, {unregister_topic, TopicName}).

-spec register_channel(binary(), binary()) -> ok.
register_channel(TopicName, ChannelName) when is_binary(TopicName), is_binary(ChannelName) ->
    gen_server:cast(?MODULE, {register_channel, TopicName, ChannelName}).

-spec unregister_channel(binary(), binary()) -> ok.
unregister_channel(TopicName, ChannelName) when is_binary(TopicName), is_binary(ChannelName) ->
    gen_server:cast(?MODULE, {unregister_channel, TopicName, ChannelName}).

-spec lookup(binary()) -> {ok, [map()]} | {error, term()}.
lookup(TopicName) when is_binary(TopicName) ->
    case gen_server:call(?MODULE, {lookup, TopicName}) of
        {ok, List} when is_list(List) ->
            %% Verify all elements are maps (type guard for eqwalizer)
            true = lists:all(fun is_map/1, List),
            {ok, List};
        {error, _} = Error -> Error
    end.

%% =============================================================================
%% gen_server callbacks
%% =============================================================================

init([]) ->
    {ok, #state{}}.

handle_call({lookup, TopicName}, _From, State) ->
    %% 桩实现：返回本地节点
    Result = case lists:member(TopicName, State#state.registered_topics) of
        true ->
            {ok, [#{hostname => node(), tcp_port => 4150}]};
        false ->
            {ok, []}
    end,
    {reply, Result, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({register_topic, TopicName}, State) ->
    NewTopics = [TopicName | [T || T <- State#state.registered_topics, T =/= TopicName]],
    logger:info("Registered topic with lookupd: ~s", [TopicName]),
    {noreply, State#state{registered_topics = NewTopics}};

handle_cast({unregister_topic, TopicName}, State) ->
    NewTopics = [T || T <- State#state.registered_topics, T =/= TopicName],
    logger:info("Unregistered topic from lookupd: ~s", [TopicName]),
    {noreply, State#state{registered_topics = NewTopics}};

handle_cast({register_channel, TopicName, ChannelName}, State) ->
    Key = {TopicName, ChannelName},
    NewChannels = [Key | [K || K <- State#state.registered_channels, K =/= Key]],
    logger:info("Registered channel with lookupd: ~s/~s", [TopicName, ChannelName]),
    {noreply, State#state{registered_channels = NewChannels}};

handle_cast({unregister_channel, TopicName, ChannelName}, State) ->
    Key = {TopicName, ChannelName},
    NewChannels = [K || K <- State#state.registered_channels, K =/= Key],
    logger:info("Unregistered channel from lookupd: ~s/~s", [TopicName, ChannelName]),
    {noreply, State#state{registered_channels = NewChannels}};

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
