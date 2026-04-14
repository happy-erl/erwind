# Backend Queue 模块 (erwind_backend_queue)

## 功能概述

Backend Queue 是消息持久化存储的核心模块，提供内存队列和磁盘队列的混合存储能力，确保消息可靠性和系统内存可控。

## 原理详解

### 存储层级

```
+------------------+
|   Producer       |
+--------+---------+
         |
+--------v---------+    满/溢出      +------------------+
|   Memory Queue   | +-------------> |    Disk Queue    |
|   (快速)         |                 |    (持久化)      |
|   - 双端队列     | <--------------+|   - 文件分段     |
|   - 优先消费     |    读取         |   - 顺序写入     |
+------------------+                 +------------------+
         |
+--------v---------+
|   Consumer       |
+------------------+
```

### 设计目标

1. **高性能**：优先使用内存队列，磁盘作为溢出
2. **可靠性**：消息持久化到磁盘，进程崩溃可恢复
3. **顺序保证**：同一 Topic/Channel 内消息有序
4. **容量控制**：内存使用可控，避免 OOM
5. **快速恢复**：重启后从磁盘恢复消息

### 磁盘队列结构

参考 NSQ 的 diskqueue 设计：

```
/data/nsq/topic-name/channel-name/
├── 00000000000000000001.dat   # 数据文件 1
├── 00000000000000000002.dat   # 数据文件 2
├── 00000000000000000003.dat   # 数据文件 3
├── meta.dat                    # 元数据文件
└── lock.file                   # 锁文件
```

数据文件格式：
```
+---------------+---------------+----------------+
|  Msg Length   |   Timestamp   |    Body        |
|   4 bytes     |    8 bytes    |  Length bytes  |
|  Big Endian   |   Big Endian  |                |
+---------------+---------------+----------------+
```

元数据文件格式：
```json
{
  "version": 1,
  "read_file_num": 1,      // 当前读取文件编号
  "read_pos": 1024,        // 当前读取位置
  "write_file_num": 3,     // 当前写入文件编号
  "write_pos": 2048,       // 当前写入位置
  "depth": 1000            // 队列深度
}
```

## Erlang 实现设计

### 模块结构

```erlang
-module(erwind_backend_queue).
-behaviour(gen_server).

%% API
-export([start_link/1, stop/1, put/2, get/1, peek/1, depth/1]).
-export([put_batch/2, get_batch/2, flush/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% 配置记录
-record(config, {
    name :: binary(),                    %% 队列名称
    data_path :: string(),               %% 数据目录
    max_bytes_per_file = 104857600 :: integer(),  %% 单个文件大小（100MB）
    sync_every = 2500 :: integer(),      %% 每 N 条消息 sync
    sync_timeout = 2000 :: integer()     %% sync 超时（毫秒）
}).

%% 状态记录
-record(state, {
    config :: #config{},
    
    %% 内存队列
    memory_queue = queue:new() :: queue:queue(),
    memory_depth = 0 :: non_neg_integer(),
    max_memory_depth = 10000 :: non_neg_integer(),
    
    %% 磁盘队列
    read_file :: file:io_device(),
    read_file_num :: integer(),
    read_pos :: integer(),
    
    write_file :: file:io_device(),
    write_file_num :: integer(),
    write_pos :: integer(),
    
    %% 统计
    disk_depth = 0 :: non_neg_integer(),
    write_count = 0 :: non_neg_integer(),
    read_count = 0 :: non_neg_integer(),
    
    %% Sync 控制
    need_sync = false :: boolean(),
    sync_timer :: reference()
}).

%% 消息记录（磁盘存储格式）
-record(disk_msg, {
    length :: integer(),
    timestamp :: integer(),
    body :: binary()
}).
```

### 核心逻辑

#### 1. 初始化

```erlang
init([Name]) ->
    process_flag(trap_exit, true),
    
    Config = #config{
        name = Name,
        data_path = get_data_path(Name),
        max_bytes_per_file = application:get_env(erwind, max_bytes_per_file, 104857600)
    },
    
    %% 创建数据目录
    ok = filelib:ensure_dir(Config#config.data_path ++ "/"),
    
    %% 加载元数据或初始化
    State = case load_meta(Config) of
        {ok, Meta} ->
            %% 恢复已有队列
            init_from_meta(Config, Meta);
        {error, enoent} ->
            %% 新建队列
            init_new_queue(Config)
    end,
    
    {ok, State}.

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
        disk_depth = 0
    }.
```

#### 2. 消息写入

```erlang
%% 写入单条消息
handle_cast({put, Body}, State) when is_binary(Body) ->
    Msg = #disk_msg{
        length = byte_size(Body),
        timestamp = erlang:system_time(millisecond),
        body = Body
    },
    
    %% 编码消息
    Data = encode_disk_msg(Msg),
    
    %% 检查是否需要切分文件
    NewState = case State#state.write_pos + byte_size(Data) > 
                       State#state.config#config.max_bytes_per_file of
        true ->
            %% 关闭当前文件，创建新文件
            rotate_write_file(State);
        false ->
            State
    end,
    
    %% 写入数据
    ok = file:write(NewState#state.write_file, Data),
    
    %% 更新状态
    UpdatedState = NewState#state{
        write_pos = NewState#state.write_pos + byte_size(Data),
        disk_depth = NewState#state.disk_depth + 1,
        write_count = NewState#state.write_count + 1,
        need_sync = true
    },
    
    %% 检查是否需要 sync
    FinalState = maybe_sync(UpdatedState),
    
    {noreply, FinalState}.

%% 批量写入
handle_cast({put_batch, Bodies}, State) when is_list(Bodies) ->
    %% 批量编码
    {DataList, NewState} = lists:foldl(fun(Body, {Acc, St}) ->
        Msg = #disk_msg{
            length = byte_size(Body),
            timestamp = erlang:system_time(millisecond),
            body = Body
        },
        Data = encode_disk_msg(Msg),
        
        %% 检查文件切分
        St2 = case St#state.write_pos + byte_size(Data) > 
                      St#state.config#config.max_bytes_per_file of
            true -> rotate_write_file(St);
            false -> St
        end,
        
        {[Data | Acc], St2}
    end, {[], State}, Bodies),
    
    %% 批量写入
    AllData = iolist_to_binary(lists:reverse(DataList)),
    ok = file:write(NewState#state.write_file, AllData),
    
    UpdatedState = NewState#state{
        write_pos = NewState#state.write_pos + byte_size(AllData),
        disk_depth = NewState#state.disk_depth + length(Bodies),
        write_count = NewState#state.write_count + length(Bodies),
        need_sync = true
    },
    
    {noreply, maybe_sync(UpdatedState)}.

%% 消息编码
encode_disk_msg(#disk_msg{length = Len, timestamp = Ts, body = Body}) ->
    <<Len:32/big, Ts:64/big, Body/binary>>.
```

#### 3. 消息读取

```erlang
%% 同步读取
handle_call(get, _From, State) ->
    case do_read(State) of
        {ok, Msg, NewState} ->
            {reply, {ok, Msg}, NewState};
        {empty, NewState} ->
            {reply, empty, NewState};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end.

%% 执行读取
do_read(State) when State#state.disk_depth == 0 ->
    {empty, State};

do_read(State) ->
    %% 读取消息头（12 字节）
    case file:read(State#state.read_file, 12) of
        {ok, <<Len:32/big, Ts:64/big>>} ->
            %% 读取消息体
            case file:read(State#state.read_file, Len) of
                {ok, Body} ->
                    Msg = #disk_msg{
                        length = Len,
                        timestamp = Ts,
                        body = Body
                    },
                    
                    NewState = State#state{
                        read_pos = State#state.read_pos + 12 + Len,
                        disk_depth = State#state.disk_depth - 1,
                        read_count = State#state.read_count + 1
                    },
                    
                    %% 检查是否需要切换读取文件
                    FinalState = maybe_rotate_read_file(NewState),
                    
                    {ok, Msg, FinalState};
                eof ->
                    %% 文件损坏或未完成
                    {error, corrupt_file}
            end;
        eof ->
            %% 检查是否有下一个文件
            case State#state.read_file_num < State#state.write_file_num of
                true ->
                    %% 切换到下一个文件
                    NewState = rotate_read_file(State),
                    do_read(NewState);
                false ->
                    {empty, State}
            end
    end.

%% 检查并切换读取文件
maybe_rotate_read_file(State) ->
    %% 检查当前位置是否到达文件末尾
    {ok, FileInfo} = file:read_file_info(get_file_path(State#state.config, 
                                                        State#state.read_file_num)),
    case State#state.read_pos >= FileInfo#file_info.size of
        true when State#state.read_file_num < State#state.write_file_num ->
            rotate_read_file(State);
        _ ->
            State
    end.

%% 切换读取文件
rotate_read_file(State) ->
    ok = file:close(State#state.read_file),
    
    %% 删除旧文件
    OldFile = get_file_path(State#state.config, State#state.read_file_num),
    ok = file:delete(OldFile),
    
    NewFileNum = State#state.read_file_num + 1,
    NewFile = open_read_file(State#state.config, NewFileNum),
    
    State#state{
        read_file = NewFile,
        read_file_num = NewFileNum,
        read_pos = 0
    }.
```

#### 4. 内存 + 磁盘混合队列

```erlang
%% 混合队列写入
handle_cast({put_hybrid, Body}, State) ->
    case State#state.memory_depth < State#state.max_memory_depth of
        true ->
            %% 写入内存队列
            NewQueue = queue:in(Body, State#state.memory_queue),
            {noreply, State#state{
                memory_queue = NewQueue,
                memory_depth = State#state.memory_depth + 1
            }};
        false ->
            %% 内存满，写入磁盘
            handle_cast({put, Body}, State)
    end.

%% 混合队列读取
handle_call(get_hybrid, _From, State) ->
    %% 优先从内存读取
    case queue:out(State#state.memory_queue) of
        {{value, Msg}, NewQueue} ->
            {reply, {ok, Msg}, State#state{
                memory_queue = NewQueue,
                memory_depth = State#state.memory_depth - 1
            }};
        {empty, _} ->
            %% 内存为空，从磁盘读取
            case do_read(State) of
                {ok, #disk_msg{body = Body}, NewState} ->
                    {reply, {ok, Body}, NewState};
                {empty, NewState} ->
                    {reply, empty, NewState}
            end
    end.
```

#### 5. 元数据管理

```erlang
%% 保存元数据
save_meta(State) ->
    Meta = #{
        version => 1,
        read_file_num => State#state.read_file_num,
        read_pos => State#state.read_pos,
        write_file_num => State#state.write_file_num,
        write_pos => State#state.write_pos,
        disk_depth => State#state.disk_depth
    },
    
    MetaFile = State#state.config#config.data_path ++ "/meta.dat",
    MetaBin = jsx:encode(Meta),
    
    %% 原子写入：先写临时文件，再重命名
    TmpFile = MetaFile ++ ".tmp",
    ok = file:write_file(TmpFile, MetaBin),
    ok = file:rename(TmpFile, MetaFile),
    
    ok.

%% 加载元数据
load_meta(Config) ->
    MetaFile = Config#config.data_path ++ "/meta.dat",
    case file:read_file(MetaFile) of
        {ok, Bin} ->
            {ok, jsx:decode(Bin, [return_maps])};
        {error, _} = Error ->
            Error
    end.

%% 定期保存元数据
handle_info(save_meta, State) ->
    ok = save_meta(State),
    Timer = erlang:send_after(5000, self(), save_meta),
    {noreply, State#state{sync_timer = Timer}}.

%% 关闭时保存
def terminate(_Reason, State) ->
    ok = save_meta(State),
    ok = file:close(State#state.read_file),
    ok = file:close(State#state.write_file),
    ok.
```

#### 6. Sync 策略

```erlang
%% 检查是否需要 sync
maybe_sync(State) ->
    Config = State#state.config,
    ShouldSync = State#state.need_sync andalso 
                 (State#state.write_count rem Config#config.sync_every == 0),
    
    case ShouldSync of
        true ->
            ok = file:sync(State#state.write_file),
            State#state{need_sync = false};
        false ->
            State
    end.

%% 定时 sync
handle_info(sync_timeout, State) when State#state.need_sync ->
    ok = file:sync(State#state.write_file),
    {noreply, State#state{need_sync = false}};
handle_info(sync_timeout, State) ->
    {noreply, State}.
```

## 依赖关系

### 依赖的模块
- `jsx` - JSON 编解码（元数据）

### 被依赖的模块
- `erwind_topic` - Topic 使用 Backend Queue
- `erwind_channel` - Channel 使用 Backend Queue
- `erwind_diskqueue_sup` - 监督者启动

## 接口定义

```erlang
%% 启动队列
-spec start_link(Name :: binary()) -> {ok, pid()}.

%% 写入消息
-spec put(Pid :: pid(), Body :: binary()) -> ok.

%% 批量写入
-spec put_batch(Pid :: pid(), Bodies :: [binary()]) -> ok.

%% 读取消息
-spec get(Pid :: pid()) -> {ok, binary()} | empty.

%% 批量读取
-spec get_batch(Pid :: pid(), Count :: integer()) -> {ok, [binary()]}.

%% 查看队列头部（不移除）
-spec peek(Pid :: pid()) -> {ok, binary()} | empty.

%% 获取队列深度
-spec depth(Pid :: pid()) -> {MemoryDepth :: integer(), DiskDepth :: integer()}.

%% 刷新所有缓冲到磁盘
-spec flush(Pid :: pid()) -> ok.

%% 关闭队列
-spec stop(Pid :: pid()) -> ok.
```

## 配置参数

```erlang
{erwind_backend_queue, [
    {data_path, "/var/lib/erwind"},       %% 数据目录
    {max_bytes_per_file, 104857600},      %% 单个文件大小（100MB）
    {max_memory_depth, 10000},            %% 内存队列最大深度
    {sync_every, 2500},                   %% 每 N 条消息 sync
    {sync_timeout, 2000},                 %% sync 超时（毫秒）
    {meta_save_interval, 5000}            %% 元数据保存间隔（毫秒）
]}.
```

## 故障恢复

### 1. 进程崩溃恢复

```erlang
%% 启动时检查未完成的写入文件
recover_from_crash(Config) ->
    %% 读取元数据
    {ok, Meta} = load_meta(Config),
    
    %% 检查写入文件是否完整
    WriteFile = get_file_path(Config, maps:get(write_file_num, Meta)),
    {ok, FileInfo} = file:read_file_info(WriteFile),
    
    case FileInfo#file_info.size > maps:get(write_pos, Meta) of
        true ->
            %% 文件有新增数据，尝试恢复
            {ok, Fd} = file:open(WriteFile, [read, binary]),
            {ok, _} = file:position(Fd, maps:get(write_pos, Meta)),
            RecoveredCount = scan_and_recover(Fd),
            file:close(Fd),
            Meta#{disk_depth => maps:get(disk_depth, Meta) + RecoveredCount};
        false ->
            Meta
    end.
```

### 2. 文件损坏处理

```erlang
%% 扫描损坏的文件，跳过损坏的消息
scan_and_recover(Fd) ->
    case file:read(Fd, 12) of
        {ok, <<Len:32/big, Ts:64/big>>} ->
            case file:read(Fd, Len) of
                {ok, _} ->
                    1 + scan_and_recover(Fd);
                eof ->
                    %% 消息不完整，回退位置
                    {ok, Pos} = file:position(Fd, {cur, -12}),
                    file:truncate(Fd),
                    0
            end;
        eof ->
            0;
        {ok, _} ->
            %% 损坏的数据，尝试跳过
            {ok, _} = file:position(Fd, {cur, 1}),
            scan_and_recover(Fd)
    end.
```
