%% erwind_backend_queue.erl
%% 后端队列模块 - 内存 + 磁盘混合存储
%% 提供高性能内存队列和可靠磁盘存储的混合能力

-module(erwind_backend_queue).
-behaviour(gen_server).

%% API
-export([start_link/1, stop/1, put/2, put_batch/2, get/1, depth/1, clear/1]).
-export([put_hybrid/2, get_hybrid/1, flush/1, peek/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include_lib("erwind/include/erwind.hrl").

-define(BACKEND_MAX_MEMORY_DEPTH, 10000).

-record(state, {
    name :: binary(),

    %% 内存队列
    memory_queue :: queue:queue(#nsq_message{}),
    memory_depth = 0 :: non_neg_integer(),
    max_memory_depth :: non_neg_integer(),

    %% 磁盘队列
    disk_queue_pid :: pid() | undefined,

    %% 统计
    total_count = 0 :: non_neg_integer()
}).

%% =============================================================================
%% API
%% =============================================================================

-spec start_link(binary()) -> gen_server:start_ret().
start_link(Name) when is_binary(Name) ->
    gen_server:start_link(?MODULE, [Name], []).

-spec stop(pid()) -> ok.
stop(Pid) when is_pid(Pid) ->
    gen_server:stop(Pid).

%% 写入消息（仅内存）
-spec put(pid(), #nsq_message{}) -> ok.
put(Pid, Msg) when is_pid(Pid), is_record(Msg, nsq_message) ->
    gen_server:cast(Pid, {put, Msg}).

%% 批量写入
-spec put_batch(pid(), [#nsq_message{}]) -> ok.
put_batch(Pid, Msgs) when is_pid(Pid), is_list(Msgs) ->
    gen_server:cast(Pid, {put_batch, Msgs}).

%% 写入消息（混合模式：优先内存，满了写磁盘）
-spec put_hybrid(pid(), #nsq_message{}) -> ok.
put_hybrid(Pid, Msg) when is_pid(Pid), is_record(Msg, nsq_message) ->
    gen_server:cast(Pid, {put_hybrid, Msg}).

%% 读取消息（仅内存）
-spec get(pid()) -> {ok, #nsq_message{}} | empty.
get(Pid) when is_pid(Pid) ->
    case gen_server:call(Pid, get) of
        {ok, Msg} when is_record(Msg, nsq_message) -> {ok, Msg};
        empty -> empty
    end.

%% 读取消息（混合模式：优先内存，空了从磁盘读）
-spec get_hybrid(pid()) -> {ok, #nsq_message{}} | empty.
get_hybrid(Pid) when is_pid(Pid) ->
    case gen_server:call(Pid, get_hybrid) of
        {ok, Msg} when is_record(Msg, nsq_message) -> {ok, Msg};
        empty -> empty
    end.

%% 查看队列头部（不移除）
-spec peek(pid()) -> {ok, #nsq_message{}} | empty.
peek(Pid) when is_pid(Pid) ->
    case gen_server:call(Pid, peek) of
        {ok, Msg} when is_record(Msg, nsq_message) -> {ok, Msg};
        empty -> empty
    end.

%% 获取队列深度
-spec depth(pid()) -> {MemoryDepth :: non_neg_integer(), DiskDepth :: non_neg_integer()}.
depth(Pid) when is_pid(Pid) ->
    Result = gen_server:call(Pid, depth),
    true = is_tuple(Result),
    true = is_integer(element(1, Result)),
    true = is_integer(element(2, Result)),
    Result.

%% 刷新缓冲到磁盘
-spec flush(pid()) -> ok.
flush(Pid) when is_pid(Pid) ->
    ok = gen_server:call(Pid, flush).

%% 清空队列
-spec clear(pid()) -> ok.
clear(Pid) when is_pid(Pid) ->
    ok = gen_server:call(Pid, clear).

%% =============================================================================
%% gen_server callbacks
%% =============================================================================

init([Name]) ->
    process_flag(trap_exit, true),

    MaxMemoryDepth0 = application:get_env(erwind, max_memory_depth, ?BACKEND_MAX_MEMORY_DEPTH),
    MaxMemoryDepth = if
        is_integer(MaxMemoryDepth0), MaxMemoryDepth0 > 0 -> MaxMemoryDepth0;
        true -> ?BACKEND_MAX_MEMORY_DEPTH
    end,

    %% 尝试启动磁盘队列
    DiskQueuePid = case code:which(erwind_disk_queue) of
        non_existing -> undefined;
        _ ->
            case erwind_disk_queue:start_link(Name) of
                {ok, Pid} -> Pid;
                _ -> undefined
            end
    end,

    {ok, #state{
        name = Name,
        memory_queue = queue:new(),
        max_memory_depth = MaxMemoryDepth,
        disk_queue_pid = DiskQueuePid
    }}.

handle_call(get, _From, State) ->
    case queue:out(State#state.memory_queue) of
        {empty, _} ->
            {reply, empty, State};
        {{value, Msg}, NewQueue} ->
            NewState = State#state{
                memory_queue = NewQueue,
                memory_depth = State#state.memory_depth - 1,
                total_count = State#state.total_count - 1
            },
            {reply, {ok, Msg}, NewState}
    end;

handle_call(get_hybrid, _From, State) ->
    %% 优先从内存读取
    case queue:out(State#state.memory_queue) of
        {{value, Msg}, NewQueue} ->
            NewState = State#state{
                memory_queue = NewQueue,
                memory_depth = State#state.memory_depth - 1,
                total_count = State#state.total_count - 1
            },
            {reply, {ok, Msg}, NewState};
        {empty, _} ->
            %% 内存为空，尝试从磁盘读取
            case read_from_disk(State) of
                {ok, Body, NewState} ->
                    %% 将 body 转换为消息
                    Msg = #nsq_message{
                        id = erwind_protocol:generate_msg_id(),
                        timestamp = erlang:system_time(millisecond),
                        attempts = 1,
                        body = Body
                    },
                    {reply, {ok, Msg}, NewState#state{
                        total_count = NewState#state.total_count - 1
                    }};
                empty ->
                    {reply, empty, State}
            end
    end;

handle_call(peek, _From, State) ->
    case queue:peek(State#state.memory_queue) of
        empty ->
            {reply, empty, State};
        {value, Msg} ->
            {reply, {ok, Msg}, State}
    end;

handle_call(depth, _From, State) ->
    DiskDepth = get_disk_depth(State),
    {reply, {State#state.memory_depth, DiskDepth}, State};

handle_call(flush, _From, State) ->
    ok = flush_disk(State),
    {reply, ok, State};

handle_call(clear, _From, State) ->
    %% 清空内存队列
    NewState = State#state{
        memory_queue = queue:new(),
        memory_depth = 0,
        total_count = 0
    },
    %% 清空磁盘队列
    ok = clear_disk(State),
    {reply, ok, NewState};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({put, Msg}, State) ->
    NewQueue = queue:in(Msg, State#state.memory_queue),
    NewState = State#state{
        memory_queue = NewQueue,
        memory_depth = State#state.memory_depth + 1,
        total_count = State#state.total_count + 1
    },
    {noreply, NewState};

handle_cast({put_batch, Msgs}, State) when is_list(Msgs) ->
    ValidMsgs = [M || M <- Msgs, is_record(M, nsq_message)],
    NewQueue = lists:foldl(
        fun(Msg, Q) -> queue:in(Msg, Q) end,
        State#state.memory_queue,
        ValidMsgs
    ),
    Count = length(ValidMsgs),
    NewState = State#state{
        memory_queue = NewQueue,
        memory_depth = State#state.memory_depth + Count,
        total_count = State#state.total_count + Count
    },
    {noreply, NewState};

handle_cast({put_hybrid, Msg}, State) ->
    case State#state.memory_depth < State#state.max_memory_depth of
        true ->
            %% 写入内存队列
            NewQueue = queue:in(Msg, State#state.memory_queue),
            NewState = State#state{
                memory_queue = NewQueue,
                memory_depth = State#state.memory_depth + 1,
                total_count = State#state.total_count + 1
            },
            {noreply, NewState};
        false ->
            %% 内存满，写入磁盘
            ok = write_to_disk(Msg#nsq_message.body, State),
            NewState = State#state{
                total_count = State#state.total_count + 1
            },
            {noreply, NewState}
    end;

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({'DOWN', _Ref, process, Pid, _Reason}, #state{disk_queue_pid = Pid} = State) ->
    %% 磁盘队列进程退出
    {noreply, State#state{disk_queue_pid = undefined}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    %% 关闭磁盘队列
    case State#state.disk_queue_pid of
        undefined -> ok;
        Pid when is_pid(Pid) ->
            try erwind_disk_queue:stop(Pid) of
                _ -> ok
            catch
                _:_ -> ok
            end
    end,
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =============================================================================
%% Internal functions
%% =============================================================================

%% 写入磁盘
write_to_disk(Body, #state{disk_queue_pid = Pid}) when is_binary(Body), is_pid(Pid) ->
    erwind_disk_queue:put(Pid, Body);
write_to_disk(_, _) ->
    ok.

%% 从磁盘读取
read_from_disk(#state{disk_queue_pid = Pid} = State) when is_pid(Pid) ->
    case erwind_disk_queue:get(Pid) of
        {ok, Body} when is_binary(Body) -> {ok, Body, State};
        empty -> empty;
        {error, _} -> empty
    end;
read_from_disk(_) ->
    empty.

%% 获取磁盘深度
get_disk_depth(#state{disk_queue_pid = Pid}) when is_pid(Pid) ->
    erwind_disk_queue:depth(Pid);
get_disk_depth(_) ->
    0.

%% 刷新磁盘缓冲
flush_disk(#state{disk_queue_pid = Pid}) when is_pid(Pid) ->
    erwind_disk_queue:flush(Pid);
flush_disk(_) ->
    ok.

%% 清空磁盘队列
clear_disk(#state{disk_queue_pid = Pid}) when is_pid(Pid) ->
    try erwind_disk_queue:clear(Pid) of
        ok -> ok;
        _ -> ok
    catch
        _:_ -> ok
    end;
clear_disk(_) ->
    ok.
