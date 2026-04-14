# HTTP API 模块 (erwind_http_api)

## 功能概述

HTTP API 提供管理接口和监控接口，用于查询统计信息、管理 Topics/Channels、调试等。

## NSQ HTTP API 规范

### 端口和路径

- **端口**: 4151（默认）
- **内容类型**: JSON

### API 端点

#### 1. 信息接口

| 方法 | 路径 | 描述 |
|------|------|------|
| GET | `/ping` | 健康检查 |
| GET | `/info` | 节点信息 |
| GET | `/stats` | 统计信息 |
| GET | `/debug/pprof/profile` | 性能分析 |

#### 2. Topic 管理

| 方法 | 路径 | 描述 |
|------|------|------|
| POST | `/topic/create?topic=<name>` | 创建 Topic |
| POST | `/topic/delete?topic=<name>` | 删除 Topic |
| POST | `/topic/empty?topic=<name>` | 清空 Topic |
| POST | `/topic/pause?topic=<name>` | 暂停 Topic |
| POST | `/topic/unpause?topic=<name>` | 恢复 Topic |
| GET | `/topic/list` | 列出所有 Topics |

#### 3. Channel 管理

| 方法 | 路径 | 描述 |
|------|------|------|
| POST | `/channel/create?topic=<t>&channel=<c>` | 创建 Channel |
| POST | `/channel/delete?topic=<t>&channel=<c>` | 删除 Channel |
| POST | `/channel/empty?topic=<t>&channel=<c>` | 清空 Channel |
| POST | `/channel/pause?topic=<t>&channel=<c>` | 暂停 Channel |
| POST | `/channel/unpause?topic=<t>&channel=<c>` | 恢复 Channel |

#### 4. 发布接口

| 方法 | 路径 | 描述 |
|------|------|------|
| POST | `/pub?topic=<name>` | 发布单条消息 |
| POST | `/mpub?topic=<name>` | 批量发布 |
| POST | `/dpub?topic=<name>&defer=<ms>` | 延迟发布 |

#### 5. 配置接口

| 方法 | 路径 | 描述 |
|------|------|------|
| GET | `/config/nsqlookupd_tcp_addresses` | 获取 lookupd 地址 |
| POST | `/config/nsqlookupd_tcp_addresses` | 设置 lookupd 地址 |

## Erlang 实现设计

### 模块结构

```erlang
-module(erwind_http_api).
-behaviour(cowboy_handler).

%% Cowboy 回调
-export([init/2]).

%% API 路由表
-export([routes/0]).

%% 内部处理函数
-export([handle_ping/2, handle_info/2, handle_stats/2, handle_pub/2]).

%% 路由配置
routes() ->
    [
        {"/ping", ?MODULE, #{handler => ping}},
        {"/info", ?MODULE, #{handler => info}},
        {"/stats", ?MODULE, #{handler => stats}},
        {"/topic/create", ?MODULE, #{handler => topic_create}},
        {"/topic/delete", ?MODULE, #{handler => topic_delete}},
        {"/topic/empty", ?MODULE, #{handler => topic_empty}},
        {"/topic/pause", ?MODULE, #{handler => topic_pause}},
        {"/topic/unpause", ?MODULE, #{handler => topic_unpause}},
        {"/topic/list", ?MODULE, #{handler => topic_list}},
        {"/channel/create", ?MODULE, #{handler => channel_create}},
        {"/channel/delete", ?MODULE, #{handler => channel_delete}},
        {"/channel/empty", ?MODULE, #{handler => channel_empty}},
        {"/channel/pause", ?MODULE, #{handler => channel_pause}},
        {"/channel/unpause", ?MODULE, #{handler => channel_unpause}},
        {"/pub", ?MODULE, #{handler => pub}},
        {"/mpub", ?MODULE, #{handler => mpub}},
        {"/dpub", ?MODULE, #{handler => dpub}}
    ].

%% Cowboy 初始化
init(Req, #{handler := Handler} = State) ->
    Method = cowboy_req:method(Req),
    handle_request(Handler, Method, Req, State).
```

### 监督者配置

```erlang
%% erwind_http_sup.erl
init([]) ->
    %% Cowboy 路由
    Dispatch = cowboy_router:compile([
        {'_', erwind_http_api:routes()}
    ]),
    
    %% 启动 Cowboy
    {ok, _} = cowboy:start_clear(
        erwind_http_listener,
        [{port, 4151}],
        #{env => #{dispatch => Dispatch}}
    ),
    
    {ok, {#{strategy => one_for_one, intensity => 10, period => 10}, []}}.
```

### 核心逻辑

#### 1. 健康检查

```erlang
handle_request(ping, <<"GET">>, Req, State) ->
    Req2 = cowboy_req:reply(200, #{<<"content-type">> => <<"text/plain">>}, 
                            <<"OK">>, Req),
    {ok, Req2, State}.

%% 节点信息
handle_request(info, <<"GET">>, Req, State) ->
    Info = #{
        version => erwind_app:version(),
        broadcast_address => get_broadcast_address(),
        hostname => get_hostname(),
        http_port => 4151,
        tcp_port => 4150,
        start_time => erwind_stats:get_start_time()
    },
    reply_json(Req, Info, State).

%% 统计信息
handle_request(stats, <<"GET">>, Req, State) ->
    Format = cowboy_req:binding(format, Req, <<"json">>),
    Stats = collect_stats(),
    
    case Format of
        <<"json">> ->
            reply_json(Req, Stats, State);
        <<"text">> ->
            reply_text(Req, format_stats_text(Stats), State)
    end.

%% 创建 Topic
handle_request(topic_create, <<"POST">>, Req, State) ->
    #{topic := TopicName} = cowboy_req:match_qs([topic], Req),
    
    case erwind_topic_manager:create_topic(TopicName) of
        {ok, _} ->
            reply_json(Req, #{message => <<"OK">>}, State);
        {error, already_exists} ->
            reply_error(Req, 409, <<"topic already exists">>, State);
        {error, Reason} ->
            reply_error(Req, 500, Reason, State)
    end.

%% 删除 Topic
handle_request(topic_delete, <<"POST">>, Req, State) ->
    #{topic := TopicName} = cowboy_req:match_qs([topic], Req),
    
    case erwind_topic_manager:delete_topic(TopicName) of
        ok ->
            reply_json(Req, #{message => <<"OK">>}, State);
        {error, not_found} ->
            reply_error(Req, 404, <<"topic not found">>, State);
        {error, Reason} ->
            reply_error(Req, 500, Reason, State)
    end.

%% 列出 Topics
handle_request(topic_list, <<"GET">>, Req, State) ->
    Topics = erwind_topic_manager:list_topics(),
    reply_json(Req, #{topics => Topics}, State).

%% 创建 Channel
handle_request(channel_create, <<"POST">>, Req, State) ->
    #{topic := TopicName, channel := ChannelName} = 
        cowboy_req:match_qs([topic, channel], Req),
    
    case erwind_topic_manager:create_channel(TopicName, ChannelName) of
        {ok, _} ->
            reply_json(Req, #{message => <<"OK">>}, State);
        {error, topic_not_found} ->
            reply_error(Req, 404, <<"topic not found">>, State);
        {error, Reason} ->
            reply_error(Req, 500, Reason, State)
    end.

%% 删除 Channel
handle_request(channel_delete, <<"POST">>, Req, State) ->
    #{topic := TopicName, channel := ChannelName} = 
        cowboy_req:match_qs([topic, channel], Req),
    
    case erwind_topic_manager:delete_channel(TopicName, ChannelName) of
        ok ->
            reply_json(Req, #{message => <<"OK">>}, State);
        {error, not_found} ->
            reply_error(Req, 404, <<"channel not found">>, State);
        {error, Reason} ->
            reply_error(Req, 500, Reason, State)
    end.

%% 发布消息
handle_request(pub, <<"POST">>, Req, State) ->
    #{topic := TopicName} = cowboy_req:match_qs([topic], Req),
    
    %% 读取请求体
    {ok, Body, Req2} = cowboy_req:read_body(Req),
    
    case erwind_topic_manager:publish(TopicName, Body) of
        ok ->
            reply_json(Req2, #{message => <<"OK">>}, State);
        {error, topic_not_found} ->
            reply_error(Req2, 404, <<"topic not found">>, State);
        {error, Reason} ->
            reply_error(Req2, 500, Reason, State)
    end.

%% 批量发布
handle_request(mpub, <<"POST">>, Req, State) ->
    #{topic := TopicName} = cowboy_req:match_qs([topic], Req),
    
    %% 读取请求体（每行一条消息）
    {ok, Body, Req2} = cowboy_req:read_body(Req),
    Messages = binary:split(Body, <<"\n">>, [global, trim_all]),
    
    case erwind_topic_manager:mpub(TopicName, Messages) of
        ok ->
            reply_json(Req2, #{message => <<"OK">>}, State);
        {error, Reason} ->
            reply_error(Req2, 500, Reason, State)
    end.

%% 延迟发布
handle_request(dpub, <<"POST">>, Req, State) ->
    #{topic := TopicName, defer := DeferMs} = 
        cowboy_req:match_qs([topic, defer], Req),
    
    {ok, Body, Req2} = cowboy_req:read_body(Req),
    
    case erwind_topic_manager:dpub(TopicName, Body, 
                                    binary_to_integer(DeferMs)) of
        ok ->
            reply_json(Req2, #{message => <<"OK">>}, State);
        {error, Reason} ->
            reply_error(Req2, 500, Reason, State)
    end.
```

### 统计信息收集

```erlang
%% 收集所有统计信息
collect_stats() ->
    Topics = collect_topic_stats(),
    #{
        version => erwind_app:version(),
        health => health_status(),
        start_time => erwind_stats:get_start_time(),
        topics => length(Topics),
        topic_list => Topics
    }.

%% 收集 Topic 统计
collect_topic_stats() ->
    lists:map(fun({TopicName, TopicPid}) ->
        Channels = erwind_topic:list_channels(TopicPid),
        #{
            name => TopicName,
            depth => erwind_topic:get_depth(TopicPid),
            message_count => erwind_topic:get_message_count(TopicPid),
            channels => [
                #{
                    name => ChName,
                    depth => erwind_channel:get_depth(ChPid),
                    consumers => erwind_channel:get_consumer_count(ChPid)
                } || {ChName, ChPid} <- Channels
            ]
        }
    end, erwind_topic_manager:list_topics_with_pids()).
```

### 响应工具函数

```erlang
%% JSON 响应
reply_json(Req, Data, State) ->
    Body = jsx:encode(Data),
    Req2 = cowboy_req:reply(200, 
                            #{<<"content-type">> => <<"application/json">>}, 
                            Body, Req),
    {ok, Req2, State}.

%% 错误响应
reply_error(Req, Code, Message, State) when is_binary(Message) ->
    Body = jsx:encode(#{message => Message}),
    Req2 = cowboy_req:reply(Code, 
                            #{<<"content-type">> => <<"application/json">>}, 
                            Body, Req),
    {ok, Req2, State}.

%% 文本响应
reply_text(Req, Text, State) ->
    Req2 = cowboy_req:reply(200, 
                            #{<<"content-type">> => <<"text/plain">>}, 
                            Text, Req),
    {ok, Req2, State}.
```

## 依赖关系

### 依赖的模块
- `cowboy` - HTTP 服务器
- `jsx` - JSON 编解码
- `erwind_topic_manager` - Topic 管理
- `erwind_topic` - Topic 操作
- `erwind_channel` - Channel 操作

### 被依赖的模块
- `erwind_http_sup` - 监督者启动

## 接口定义

```erlang
%% 获取路由表
-spec routes() -> cowboy_router:routes().

%% 初始化处理
-spec init(Req :: cowboy_req:req(), State :: map()) -> 
    {ok, cowboy_req:req(), map()}.
```

## 配置参数

```erlang
{erwind_http, [
    {port, 4151},                    %% HTTP 端口
    {max_connections, 1000},         %% 最大连接数
    {idle_timeout, 60000}            %% 空闲超时（毫秒）
]}.
```

## Stats 输出格式示例

```json
{
  "version": "0.1.0",
  "health": "OK",
  "start_time": "2026-04-14T10:30:00Z",
  "topics": 2,
  "topic_list": [
    {
      "name": "orders",
      "depth": 100,
      "message_count": 10000,
      "channels": [
        {
          "name": "workers",
          "depth": 50,
          "consumers": 3
        },
        {
          "name": "archiver",
          "depth": 0,
          "consumers": 1
        }
      ]
    }
  ]
}
```
