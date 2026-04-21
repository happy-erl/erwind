%% erwind_disk_queue.erl
%% 磁盘队列模块 - 文件持久化存储
%% 实现文件分段存储和顺序写入

-module(erwind_disk_queue).
-behaviour(gen_server).

%% API
-export([start_link/1, stop/1, put/2, get/1, depth/1, flush/1, clear/1]).
-export([put_batch/2, get_batch/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include_lib("erwind/include/erwind.hrl").

-define(DISKQ_MAX_BYTES_PER_FILE, 104857600).  %% 100MB
-define(DISKQ_SYNC_EVERY, 2500).
-define(DISKQ_SYNC_TIMEOUT, 2000).
-define(META_SAVE_INTERVAL, 5000).

-record(config, {
    name :: binary(),
    data_path :: string(),
    max_bytes_per_file = ?DISKQ_MAX_BYTES_PER_FILE :: non_neg_integer(),
    sync_every = ?DISKQ_SYNC_EVERY :: non_neg_integer(),
    sync_timeout = ?DISKQ_SYNC_TIMEOUT :: non_neg_integer()
}).

-record(state, {
    config :: #config{},

    %% 文件句柄
    read_file :: file:io_device() | undefined,
    read_file_num = 1 :: non_neg_integer(),
    read_pos = 0 :: non_neg_integer(),

    write_file :: file:io_device() | undefined,
    write_file_num = 1 :: non_neg_integer(),
    write_pos = 0 :: non_neg_integer(),

    %% 统计
    depth = 0 :: non_neg_integer(),
    write_count = 0 :: non_neg_integer(),
    read_count = 0 :: non_neg_integer(),

    %% Sync 控制
    need_sync = false :: boolean(),
    meta_timer :: reference() | undefined
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

-spec put(pid(), binary()) -> ok.
put(Pid, Body) when is_pid(Pid), is_binary(Body) ->
    gen_server:cast(Pid, {put, Body}).

-spec put_batch(pid(), [binary()]) -> ok.
put_batch(Pid, Bodies) when is_pid(Pid), is_list(Bodies) ->
    gen_server:cast(Pid, {put_batch, Bodies}).

-spec get(pid()) -> {ok, binary()} | empty | {error, term()}.
get(Pid) when is_pid(Pid) ->
    case gen_server:call(Pid, get) of
        {ok, Body} when is_binary(Body) -> {ok, Body};
        empty -> empty;
        {error, _} = E -> E
    end.

-spec get_batch(pid(), non_neg_integer()) -> {ok, [binary()]}.
get_batch(Pid, Count) when is_pid(Pid), is_integer(Count), Count >= 0 ->
    Result = gen_server:call(Pid, {get_batch, Count}),
    case Result of
        {ok, List} when is_list(List) ->
            Binaries = [B || B <- List, is_binary(B)],
            {ok, Binaries};
        _ -> {ok, []}
    end.

-spec depth(pid()) -> non_neg_integer().
depth(Pid) when is_pid(Pid) ->
    Result = gen_server:call(Pid, depth),
    true = is_integer(Result),
    Result.

-spec flush(pid()) -> ok.
flush(Pid) when is_pid(Pid) ->
    ok = gen_server:call(Pid, flush).

-spec clear(pid()) -> ok.
clear(Pid) when is_pid(Pid) ->
    ok = gen_server:call(Pid, clear).

%% =============================================================================
%% gen_server callbacks
%% =============================================================================

init([Name]) ->
    process_flag(trap_exit, true),

    MaxBytesPerFile0 = application:get_env(erwind, max_bytes_per_file, ?DISKQ_MAX_BYTES_PER_FILE),
    SyncEvery0 = application:get_env(erwind, sync_every, ?DISKQ_SYNC_EVERY),
    SyncTimeout0 = application:get_env(erwind, sync_timeout, ?DISKQ_SYNC_TIMEOUT),

    MaxBytesPerFile = if is_integer(MaxBytesPerFile0), MaxBytesPerFile0 > 0 -> MaxBytesPerFile0; true -> ?DISKQ_MAX_BYTES_PER_FILE end,
    SyncEvery = if is_integer(SyncEvery0), SyncEvery0 > 0 -> SyncEvery0; true -> ?DISKQ_SYNC_EVERY end,
    SyncTimeout = if is_integer(SyncTimeout0), SyncTimeout0 > 0 -> SyncTimeout0; true -> ?DISKQ_SYNC_TIMEOUT end,

    Config = #config{
        name = Name,
        data_path = get_data_path(Name),
        max_bytes_per_file = MaxBytesPerFile,
        sync_every = SyncEvery,
        sync_timeout = SyncTimeout
    },

    %% 创建数据目录
    ok = filelib:ensure_dir(Config#config.data_path ++ "/"),

    %% 加载元数据或初始化新队列
    State = case load_meta(Config) of
        {ok, Meta} ->
            init_from_meta(Config, Meta);
        {error, _} ->
            init_new_queue(Config)
    end,

    %% 启动定期保存元数据
    MetaTimer = erlang:send_after(?META_SAVE_INTERVAL, self(), save_meta),

    {ok, State#state{meta_timer = MetaTimer}}.

handle_call(get, _From, State) ->
    case do_read(State) of
        {ok, Body, NewState} ->
            {reply, {ok, Body}, NewState};
        {empty, NewState} ->
            {reply, empty, NewState};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call({get_batch, Count}, _From, State) ->
    {Bodies, NewState} = do_read_batch(Count, [], State),
    {reply, {ok, lists:reverse(Bodies)}, NewState};

handle_call(depth, _From, State) ->
    {reply, State#state.depth, State};

handle_call(flush, _From, State) when State#state.need_sync ->
    case State#state.write_file of
        undefined -> ok;
        WriteFile -> ok = file:sync(WriteFile)
    end,
    {reply, ok, State#state{need_sync = false}};

handle_call(flush, _From, State) ->
    {reply, ok, State};

handle_call(clear, _From, State) ->
    %% 关闭当前文件句柄
    case State#state.write_file of
        undefined -> ok;
        WriteFd -> file:close(WriteFd)
    end,
    case State#state.read_file of
        undefined -> ok;
        ReadFd -> file:close(ReadFd)
    end,
    %% 删除所有数据文件
    DataPath = State#state.config#config.data_path,
    Name = State#state.config#config.name,
    QueueDir = filename:join(DataPath, binary_to_list(Name)),
    catch file:del_dir_r(QueueDir),
    catch file:make_dir(QueueDir),
    %% 重新初始化状态
    {reply, ok, State#state{
        read_file = undefined,
        read_file_num = 1,
        read_pos = 0,
        write_file = undefined,
        write_file_num = 1,
        write_pos = 0,
        depth = 0,
        write_count = 0,
        read_count = 0,
        need_sync = false
    }};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({put, Body}, State) when is_binary(Body) ->
    Data = encode_message(Body),

    %% 检查是否需要切分文件
    NewState = maybe_rotate_write_file(Data, State),

    %% 写入数据
    ok = file:write(NewState#state.write_file, Data),

    UpdatedState = NewState#state{
        write_pos = NewState#state.write_pos + byte_size(Data),
        depth = NewState#state.depth + 1,
        write_count = NewState#state.write_count + 1,
        need_sync = true
    },

    {noreply, maybe_sync(UpdatedState)};

handle_cast({put_batch, Bodies}, State) when is_list(Bodies) ->
    %% 编码所有消息
    {DataList, NewState} = lists:foldl(
        fun(Body, {Acc, St}) when is_binary(Body), is_list(Acc), is_record(St, state) ->
                Data = encode_message(Body),
                St2 = maybe_rotate_write_file(Data, St),
                {[Data | Acc], St2};
           (_, Acc) -> Acc
        end,
        {[], State},
        Bodies
    ),

    %% 批量写入
    true = is_list(DataList),
    true = is_record(NewState, state),
    AllData = iolist_to_binary(lists:reverse(DataList)),
    ok = file:write(NewState#state.write_file, AllData),

    UpdatedState = NewState#state{
        write_pos = NewState#state.write_pos + byte_size(AllData),
        depth = NewState#state.depth + length(Bodies),
        write_count = NewState#state.write_count + length(Bodies),
        need_sync = true
    },

    {noreply, maybe_sync(UpdatedState)};

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(save_meta, State) ->
    ok = save_meta(State),
    MetaTimer = erlang:send_after(?META_SAVE_INTERVAL, self(), save_meta),
    {noreply, State#state{meta_timer = MetaTimer}};

handle_info(sync_timeout, State) when State#state.need_sync ->
    case State#state.write_file of
        undefined -> ok;
        WriteFile -> ok = file:sync(WriteFile)
    end,
    {noreply, State#state{need_sync = false}};

handle_info(sync_timeout, State) ->
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    %% 保存元数据
    ok = save_meta(State),

    %% 关闭文件句柄
    case State#state.read_file of
        undefined -> ok;
        ReadFile -> file:close(ReadFile)
    end,
    case State#state.write_file of
        undefined -> ok;
        WriteFile -> file:close(WriteFile)
    end,
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =============================================================================
%% Internal functions
%% =============================================================================

%% 获取数据目录
get_data_path(Name) ->
    BasePath0 = application:get_env(erwind, data_path, "/tmp/erwind"),
    BasePath = if is_list(BasePath0) -> BasePath0; true -> "/tmp/erwind" end,
    filename:join([BasePath, binary_to_list(Name)]).

%% 编码消息
encode_message(Body) ->
    Len = byte_size(Body),
    Ts = erlang:system_time(millisecond),
    <<Len:32/big, Ts:64/big, Body/binary>>.

%% 初始化新队列
init_new_queue(Config) ->
    ReadFileNum = 1,
    WriteFileNum = 1,

    ReadFile = open_read_file(Config, ReadFileNum),
    WriteFile = open_write_file(Config, WriteFileNum),

    #state{
        config = Config,
        read_file = ReadFile,
        read_file_num = ReadFileNum,
        read_pos = 0,
        write_file = WriteFile,
        write_file_num = WriteFileNum,
        write_pos = 0,
        depth = 0
    }.

%% 从元数据初始化
init_from_meta(Config, Meta) ->
    ReadFileNum = maps:get(<<"read_file_num">>, Meta, 1),
    ReadPos = maps:get(<<"read_pos">>, Meta, 0),
    WriteFileNum = maps:get(<<"write_file_num">>, Meta, 1),
    WritePos = maps:get(<<"write_pos">>, Meta, 0),
    Depth = maps:get(<<"depth">>, Meta, 0),

    ReadFile = open_read_file(Config, ReadFileNum),
    WriteFile = open_write_file(Config, WriteFileNum),

    %% 设置读取位置
    case ReadFile of
        undefined -> ok;
        _ -> {ok, _} = file:position(ReadFile, {bof, ReadPos})
    end,

    %% 设置写入位置
    case WriteFile of
        undefined -> ok;
        _ -> {ok, _} = file:position(WriteFile, {bof, WritePos})
    end,

    #state{
        config = Config,
        read_file = ReadFile,
        read_file_num = ReadFileNum,
        read_pos = ReadPos,
        write_file = WriteFile,
        write_file_num = WriteFileNum,
        write_pos = WritePos,
        depth = Depth
    }.

%% 打开读取文件
open_read_file(Config, FileNum) ->
    FilePath = get_file_path(Config, FileNum),
    case file:open(FilePath, [read, binary, raw]) of
        {ok, Fd} -> Fd;
        {error, _} -> undefined
    end.

%% 打开写入文件
open_write_file(Config, FileNum) ->
    FilePath = get_file_path(Config, FileNum),
    case file:open(FilePath, [write, binary, raw, append]) of
        {ok, Fd} -> Fd;
        {error, _} -> undefined
    end.

%% 获取文件路径
get_file_path(Config, FileNum) ->
    Filename = lists:flatten(io_lib:format("~20..0w.dat", [FileNum])),
    filename:join([Config#config.data_path, Filename]).

%% 执行读取
do_read(State) when State#state.depth == 0 ->
    {empty, State};

do_read(State) ->
    case State#state.read_file of
        undefined ->
            {empty, State};
        ReadFile ->
            case file:read(ReadFile, 12) of
                {ok, <<Len:32/big, _Ts:64/big>>} ->
                    case file:read(ReadFile, Len) of
                        {ok, Body} ->
                            NewState = State#state{
                                read_pos = State#state.read_pos + 12 + Len,
                                depth = State#state.depth - 1,
                                read_count = State#state.read_count + 1
                            },
                            FinalState = maybe_rotate_read_file(NewState),
                            {ok, Body, FinalState};
                        eof ->
                            {error, corrupt_file}
                    end;
                eof ->
                    %% 检查是否有下一个文件
                    case State#state.read_file_num < State#state.write_file_num of
                        true ->
                            NewState = rotate_read_file(State),
                            do_read(NewState);
                        false ->
                            {empty, State}
                    end;
                {error, _} = E ->
                    E
            end
    end.

%% 批量读取
do_read_batch(0, Acc, State) ->
    {Acc, State};
do_read_batch(Count, Acc, State) ->
    case do_read(State) of
        {ok, Body, NewState} ->
            do_read_batch(Count - 1, [Body | Acc], NewState);
        {empty, NewState} ->
            {Acc, NewState};
        {error, _} ->
            {Acc, State}
    end.

%% 检查并切换写入文件
maybe_rotate_write_file(Data, State) ->
    NewPos = State#state.write_pos + byte_size(Data),
    case NewPos > State#state.config#config.max_bytes_per_file of
        true -> rotate_write_file(State);
        false -> State
    end.

%% 切换写入文件
rotate_write_file(State) ->
    %% 关闭当前文件
    case State#state.write_file of
        undefined -> ok;
        WriteFile -> ok = file:close(WriteFile)
    end,

    NewFileNum = State#state.write_file_num + 1,
    NewFile = open_write_file(State#state.config, NewFileNum),

    State#state{
        write_file = NewFile,
        write_file_num = NewFileNum,
        write_pos = 0
    }.

%% 检查并切换读取文件
maybe_rotate_read_file(State) ->
    case State#state.read_file of
        undefined -> State;
        _ ->
            case State#state.read_file_num < State#state.write_file_num of
                true ->
                    %% 检查当前文件是否读完
                    FilePath = get_file_path(State#state.config, State#state.read_file_num),
                    case file:read_file_info(FilePath) of
                        {ok, FileInfo} ->
                            case FileInfo of
                                {file_info, Size, _, _, _, _, _, _, _, _, _, _, _, _}
                                  when State#state.read_pos >= Size ->
                                    rotate_read_file(State);
                                _ ->
                                    State
                            end;
                        _ ->
                            State
                    end;
                false ->
                    State
            end
    end.

%% 切换读取文件
rotate_read_file(State) ->
    %% 关闭当前文件
    case State#state.read_file of
        undefined -> ok;
        ReadFile -> ok = file:close(ReadFile)
    end,

    %% 删除已读完的文件
    OldFile = get_file_path(State#state.config, State#state.read_file_num),
    file:delete(OldFile),

    NewFileNum = State#state.read_file_num + 1,
    NewFile = open_read_file(State#state.config, NewFileNum),

    State#state{
        read_file = NewFile,
        read_file_num = NewFileNum,
        read_pos = 0
    }.

%% 检查是否需要 sync
maybe_sync(State) ->
    Config = State#state.config,
    ShouldSync = State#state.need_sync andalso
                 (State#state.write_count rem Config#config.sync_every == 0),

    case ShouldSync of
        true ->
            case State#state.write_file of
                undefined -> State;
                WriteFile ->
                    ok = file:sync(WriteFile),
                    State#state{need_sync = false}
            end;
        false ->
            State
    end.

%% 保存元数据
save_meta(State) ->
    Meta = #{
        <<"version">> => 1,
        <<"read_file_num">> => State#state.read_file_num,
        <<"read_pos">> => State#state.read_pos,
        <<"write_file_num">> => State#state.write_file_num,
        <<"write_pos">> => State#state.write_pos,
        <<"depth">> => State#state.depth
    },

    DataPath = State#state.config#config.data_path,
    MetaFile = filename:join([DataPath, "meta.dat"]),

    %% 简单 JSON 编码（避免依赖 jsx）
    MetaBin = encode_meta_json(Meta),

    %% 原子写入
    TmpFile = filename:join([DataPath, "meta.dat.tmp"]),
    ok = file:write_file(TmpFile, MetaBin),
    ok = file:rename(TmpFile, MetaFile),

    ok.

%% 加载元数据
load_meta(Config) ->
    MetaFile = filename:join([Config#config.data_path, "meta.dat"]),
    case file:read_file(MetaFile) of
        {ok, Bin} ->
            {ok, decode_meta_json(Bin)};
        {error, _} = Error ->
            Error
    end.

%% 简单 JSON 编码
encode_meta_json(Meta) ->
    Pairs = maps:to_list(Meta),
    Strs = [io_lib:format("\"~s\":~p", [K, V]) || {K, V} <- Pairs],
    Joined = string:join([unicode:characters_to_list(S) || S <- Strs], ","),
    unicode:characters_to_binary([${, Joined, $}]).

%% 简单 JSON 解码
decode_meta_json(Bin) ->
    %% 移除大括号
    Content = binary:replace(Bin, [<<"{">>, <<"}">>], <<>>, [global]),
    %% 分割键值对
    Pairs = binary:split(Content, <<",">>, [global]),
    lists:foldl(fun(Pair, Acc) when is_binary(Pair), is_map(Acc) ->
        case binary:split(Pair, <<":">>) of
            [Key, Value] when is_binary(Key), is_binary(Value) ->
                %% 移除引号
                K = binary:replace(Key, <<"\"">>, <<>>, [global]),
                V = try binary_to_integer(Value) of
                        N -> N
                    catch
                        _:_ -> 0
                    end,
                Acc#{K => V};
            _ ->
                Acc
        end;
        (_, Acc) -> Acc
    end, #{}, Pairs).
