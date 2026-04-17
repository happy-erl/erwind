%% erwind_backend_queue.erl
%% 后端队列桩 - 消息持久化
%% TODO: 完整实现需要添加磁盘队列逻辑

-module(erwind_backend_queue).
-behaviour(gen_server).

%% API
-export([start_link/1, put/2, put_batch/2, get/1, delete/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("../include/erwind.hrl").

-record(state, {
    topic_name :: binary(),
    memory_queue = queue:new(),
    disk_queue = undefined  %% TODO: 实现磁盘队列
}).

%% =============================================================================
%% API
%% =============================================================================

-spec start_link(binary()) -> gen_server:start_ret().
start_link(TopicName) when is_binary(TopicName) ->
    gen_server:start_link(?MODULE, [TopicName], []).

-spec put(pid(), #nsq_message{}) -> ok.
put(Pid, Msg) when is_pid(Pid), is_record(Msg, nsq_message) ->
    gen_server:cast(Pid, {put, Msg}).

-spec put_batch(pid(), [#nsq_message{}]) -> ok.
put_batch(Pid, Msgs) when is_pid(Pid), is_list(Msgs) ->
    gen_server:cast(Pid, {put_batch, Msgs}).

-spec get(pid()) -> {ok, #nsq_message{}} | empty.
get(Pid) when is_pid(Pid) ->
    Result = gen_server:call(Pid, get),
    %% Type guard for eqwalizer
    case Result of
        {ok, Msg} when is_record(Msg, nsq_message) -> Result;
        empty -> empty
    end.

-spec delete(pid()) -> ok.
delete(Pid) when is_pid(Pid) ->
    gen_server:stop(Pid).

%% =============================================================================
%% gen_server callbacks
%% =============================================================================

init([TopicName]) ->
    {ok, #state{topic_name = TopicName}}.

handle_call(get, _From, State) ->
    case queue:out(State#state.memory_queue) of
        {empty, _} ->
            {reply, empty, State};
        {{value, Msg}, NewQueue} ->
            {reply, {ok, Msg}, State#state{memory_queue = NewQueue}}
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({put, Msg}, State) ->
    NewQueue = queue:in(Msg, State#state.memory_queue),
    {noreply, State#state{memory_queue = NewQueue}};

handle_cast({put_batch, Msgs}, State) ->
    NewQueue = lists:foldl(
        fun(Msg, Q) when is_record(Msg, nsq_message) -> queue:in(Msg, Q) end,
        State#state.memory_queue,
        Msgs
    ),
    {noreply, State#state{memory_queue = NewQueue}};

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
