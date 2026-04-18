%% erwind_memory_queue.erl
%% 内存队列模块 - 消息内存缓冲

-module(erwind_memory_queue).
-behaviour(gen_server).

%% API
-export([start_link/0, start_link/1, in/2, out/1, push_front/2,
         len/1, is_empty/1, clear/1, get_all/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include_lib("erwind/include/erwind.hrl").

-record(state, {
    queue = queue:new() :: queue:queue(#nsq_message{}),
    max_size = 10000 :: non_neg_integer(),
    overflow_count = 0 :: non_neg_integer()
}).

%% =============================================================================
%% API
%% =============================================================================

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link(?MODULE, [], []).

-spec start_link(non_neg_integer()) -> gen_server:start_ret().
start_link(MaxSize) when is_integer(MaxSize), MaxSize >= 0 ->
    gen_server:start_link(?MODULE, [MaxSize], []).

-spec in(pid(), #nsq_message{}) -> ok | {error, full}.
in(Pid, Msg) when is_pid(Pid), is_record(Msg, nsq_message) ->
    case gen_server:call(Pid, {in, Msg}) of
        ok -> ok;
        {error, full} -> {error, full}
    end.

-spec out(pid()) -> {ok, #nsq_message{}} | empty.
out(Pid) when is_pid(Pid) ->
    case gen_server:call(Pid, out) of
        {ok, Msg} when is_record(Msg, nsq_message) -> {ok, Msg};
        empty -> empty
    end.

-spec push_front(pid(), #nsq_message{}) -> ok.
push_front(Pid, Msg) when is_pid(Pid), is_record(Msg, nsq_message) ->
    ok = gen_server:call(Pid, {push_front, Msg}).

-spec len(pid()) -> non_neg_integer().
len(Pid) when is_pid(Pid) ->
    Result = gen_server:call(Pid, len),
    true = is_integer(Result),
    Result.

-spec is_empty(pid()) -> boolean().
is_empty(Pid) when is_pid(Pid) ->
    Result = gen_server:call(Pid, is_empty),
    true = is_boolean(Result),
    Result.

-spec clear(pid()) -> ok.
clear(Pid) when is_pid(Pid) ->
    ok = gen_server:call(Pid, clear).

-spec get_all(pid()) -> [#nsq_message{}].
get_all(Pid) when is_pid(Pid) ->
    Result = gen_server:call(Pid, get_all),
    true = is_list(Result),
    [M || M <- Result, is_record(M, nsq_message)].

%% =============================================================================
%% gen_server callbacks
%% =============================================================================

init([]) ->
    {ok, #state{}};

init([MaxSize]) ->
    {ok, #state{max_size = MaxSize}}.

handle_call({in, Msg}, _From, #state{queue = Q, max_size = Max} = State) ->
    CurrentLen = queue:len(Q),
    case CurrentLen >= Max of
        true ->
            {reply, {error, full}, State#state{overflow_count = State#state.overflow_count + 1}};
        false ->
            NewQueue = queue:in(Msg, Q),
            {reply, ok, State#state{queue = NewQueue}}
    end;

handle_call(out, _From, #state{queue = Q} = State) ->
    case queue:out(Q) of
        {empty, _} ->
            {reply, empty, State};
        {{value, Msg}, NewQueue} ->
            {reply, {ok, Msg}, State#state{queue = NewQueue}}
    end;

handle_call({push_front, Msg}, _From, #state{queue = Q} = State) ->
    NewQueue = queue:in_r(Msg, Q),
    {reply, ok, State#state{queue = NewQueue}};

handle_call(len, _From, #state{queue = Q} = State) ->
    {reply, queue:len(Q), State};

handle_call(is_empty, _From, #state{queue = Q} = State) ->
    {reply, queue:is_empty(Q), State};

handle_call(clear, _From, State) ->
    {reply, ok, State#state{queue = queue:new(), overflow_count = 0}};

handle_call(get_all, _From, #state{queue = Q} = State) ->
    {reply, queue:to_list(Q), State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
