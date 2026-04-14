# NSQLookupd 客户端模块 (erwind_lookupd)

## 功能概述

NSQLookupd 客户端负责与 nsqlookupd 集群通信，实现服务发现和节点注册。生产者通过查询 nsqlookupd 发现节点，消费者通过 nsqlookupd 发现 Topic 所在节点。

## 原理详解

### 服务发现模型

```
+-------------+        +-------------------+        +-------------+
|  Producer   | -----> |   nsqlookupd      | <----- |   nsqd      |
|  (Discover) |        |   (Registry)      |        |   (Register)|
+-------------+        +-------------------+        +-------------+
                              ^
                              |
+-------------+               |
|  Consumer   | --------------+
|  (Discover) |
+-------------+
```

### 注册流程

1. **nsqd 启动** -> 向所有配置的 nsqlookupd 注册
2. **创建 Topic** -> 向 nsqlookupd 注册 Topic
3. **创建 Channel** -> 向 nsqlookupd 注册 Channel
4. **心跳** -> 定期发送心跳保持连接
5. **关闭** -> 取消注册

### 发现流程

1. **Producer** 查询 nsqlookupd 获取 Topic 所在节点
2. **Consumer** 查询 nsqlookupd 获取 Topic 所在节点
3. 客户端缓存查询结果，定期刷新

## Erlang 实现设计

### 模块结构

```erlang
-module(erwind_lookupd).
-behaviour(gen_server).

%% API
-export([start_link/0, register_topic/1, register_channel/2]).
-export([lookup_topic/1, lookup_channels/1, lookup_nodes/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {
    lookupd_addrs = [] :: [string()],    %% nsqlookupd 地址列表
    registered_topics = #{} :: #{binary() => boolean()},  %% 已注册 Topics
    registered_channels = #{} :: #{{binary(), binary()} => boolean()},
    heartbeat_timer :: reference(),
    http_client :: pid()
}).

-define(HEARTBEAT_INTERVAL, 15000).  %% 15 秒心跳
```

### 核心逻辑

#### 1. 初始化

```erlang
init([]) ->
    %% 从配置获取 nsqlookupd 地址
    Addrs = application:get_env(erwind, nsqlookupd_tcp_addresses, []),
    
    %% 启动 HTTP 客户端
    {ok, HttpClient} = hackney_pool:start_pool(lookupd_pool, []),
    
    %% 启动心跳定时器
    Timer = erlang:send_after(?HEARTBEAT_INTERVAL, self(), heartbeat),
    
    {ok, #state{
        lookupd_addrs = Addrs,
        heartbeat_timer = Timer,
        http_client = HttpClient
    }}.
```

#### 2. 注册 Topic

```erlang
%% 注册 Topic 到所有 nsqlookupd
handle_cast({register_topic, Topic}, State) ->
    lists:foreach(fun(Addr) ->
        register_topic_to_addr(Addr, Topic, State)
    end, State#state.lookupd_addrs),
    
    NewTopics = maps:put(Topic, true, State#state.registered_topics),
    {noreply, State#state{registered_topics = NewTopics}}.

%% 向单个 nsqlookupd 注册
register_topic_to_addr(Addr, Topic, State) ->
    Url = io_lib:format("http://~s/topic/create?topic=~s", 
                        [Addr, http_uri:encode(binary_to_list(Topic))]),
    
    ReqBody = #{
        topic => Topic,
        address => get_broadcast_address(),
        http_port => 4151,
        tcp_port => 4150
    },
    
    case hackney:post(Url, [], jsx:encode(ReqBody), [with_body]) of
        {ok, 200, _Headers, _Body} ->
            ok;
        {ok, Status, _Headers, Body} ->
            error_logger:warning_msg("Register topic failed: ~p ~p ~p", 
                                     [Addr, Status, Body]);
        {error, Reason} ->
            error_logger:warning_msg("Register topic error: ~p ~p", 
                                     [Addr, Reason])
    end.
```

#### 3. 注册 Channel

```erlang
%% 注册 Channel
handle_cast({register_channel, Topic, Channel}, State) ->
    lists:foreach(fun(Addr) ->
        register_channel_to_addr(Addr, Topic, Channel, State)
    end, State#state.lookupd_addrs),
    
    NewChannels = maps:put({Topic, Channel}, true, 
                           State#state.registered_channels),
    {noreply, State#state{registered_channels = NewChannels}}.

register_channel_to_addr(Addr, Topic, Channel, State) ->
    Url = io_lib:format("http://~s/channel/create?topic=~s&channel=~s",
                        [Addr, http_uri:encode(binary_to_list(Topic)),
                         http_uri:encode(binary_to_list(Channel))]),
    
    ReqBody = #{
        topic => Topic,
        channel => Channel,
        address => get_broadcast_address(),
        http_port => 4151,
        tcp_port => 4150
    },
    
    hackney:post(Url, [], jsx:encode(ReqBody), [with_body]).
```

#### 4. 心跳机制

```erlang
%% 心跳定时器
handle_info(heartbeat, State) ->
    %% 重新注册所有 Topics 和 Channels
    lists:foreach(fun({Topic, _}) ->
        lists:foreach(fun(Addr) ->
            register_topic_to_addr(Addr, Topic, State)
        end, State#state.lookupd_addrs)
    end, maps:to_list(State#state.registered_topics)),
    
    lists:foreach(fun({{Topic, Channel}, _}) ->
        lists:foreach(fun(Addr) ->
            register_channel_to_addr(Addr, Topic, Channel, State)
        end, State#state.lookupd_addrs)
    end, maps:to_list(State#state.registered_channels)),
    
    %% 重启定时器
    Timer = erlang:send_after(?HEARTBEAT_INTERVAL, self(), heartbeat),
    {noreply, State#state{heartbeat_timer = Timer}}.
```

#### 5. 查询接口

```erlang
%% 查询 Topic 所在节点
handle_call({lookup_topic, Topic}, _From, State) ->
    Results = lists:foldl(fun(Addr, Acc) ->
        case lookup_topic_from_addr(Addr, Topic) of
            {ok, Nodes} -> Acc ++ Nodes;
            {error, _} -> Acc
        end
    end, [], State#state.lookupd_addrs),
    
    %% 去重
    UniqueResults = lists:usort(Results),
    {reply, {ok, UniqueResults}, State}.

%% 从单个 nsqlookupd 查询
lookup_topic_from_addr(Addr, Topic) ->
    Url = io_lib:format("http://~s/lookup?topic=~s",
                        [Addr, http_uri:encode(binary_to_list(Topic))]),
    
    case hackney:get(Url, [], "", [with_body]) of
        {ok, 200, _Headers, Body} ->
            Data = jsx:decode(Body, [return_maps]),
            {ok, maps:get(<<"producers">>, Data, [])};
        {ok, 404, _, _} ->
            {error, not_found};
        {error, Reason} ->
            {error, Reason}
    end.

%% 查询所有节点
handle_call(lookup_nodes, _From, State) ->
    Results = lists:foldl(fun(Addr, Acc) ->
        case lookup_nodes_from_addr(Addr) of
            {ok, Nodes} -> Acc ++ Nodes;
            {error, _} -> Acc
        end
    end, [], State#state.lookupd_addrs),
    
    {reply, {ok, lists:usort(Results)}, State}.

lookup_nodes_from_addr(Addr) ->
    Url = io_lib:format("http://~s/nodes", [Addr]),
    
    case hackney:get(Url, [], "", [with_body]) of
        {ok, 200, _Headers, Body} ->
            Data = jsx:decode(Body, [return_maps]),
            {ok, maps:get(<<"producers">>, Data, [])};
        {error, Reason} ->
            {error, Reason}
    end.
```

## 依赖关系

### 依赖的模块
- `hackney` - HTTP 客户端
- `jsx` - JSON 编解码

### 被依赖的模块
- `erwind_topic` - 创建 Topic 时注册
- `erwind_channel` - 创建 Channel 时注册

## 接口定义

```erlang
%% 注册 Topic
-spec register_topic(Topic :: binary()) -> ok.

%% 注册 Channel
-spec register_channel(Topic :: binary(), Channel :: binary()) -> ok.

%% 查询 Topic
-spec lookup_topic(Topic :: binary()) -> {ok, [map()]} | {error, term()}.

%% 查询所有节点
-spec lookup_nodes() -> {ok, [map()]} | {error, term()}.
```
