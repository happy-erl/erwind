# 协议处理模块 (erwind_protocol)

## 功能概述

协议处理模块负责 NSQ TCP 协议 V2 的编解码，包括帧格式解析、命令解析和响应生成。

## NSQ 协议详解

### 帧格式

NSQ 使用 Big Endian 字节序。

#### 基本帧结构

```
+---------------+---------------+-------------------+
|  Frame Type   |    Length     |       Body        |
|   4 bytes     |    4 bytes    |    Length bytes   |
+---------------+---------------+-------------------+
```

#### Frame Type

| 值 | 名称 | 说明 |
|----|------|------|
| 0 | FrameTypeResponse | 成功响应，Body 为 "OK" 或 JSON |
| 1 | FrameTypeError | 错误响应，Body 为错误码字符串 |
| 2 | FrameTypeMessage | 消息推送，Body 为序列化消息 |

### 消息结构（FrameTypeMessage）

```
+------------------+------------------+------------------+------------------+
|  Timestamp       |  Attempts        |   Message ID     |    Body          |
|   8 bytes        |   2 bytes        |    16 bytes      |   Variable       |
|  Big Endian      |   Big Endian     |    Hex String    |
+------------------+------------------+------------------+------------------+
```

### 命令格式

命令使用 `\n` 结尾的文本行，部分命令后跟二进制数据。

#### 1. IDENTIFY

```
命令行: "IDENTIFY\n"
数据: 4 字节 body 长度 + JSON body

JSON Body 示例:
{
    "client_id": "worker-1",
    "hostname": "worker1.example.com",
    "feature_negotiation": true,
    "heartbeat_interval": 30000,
    "output_buffer_size": 16384,
    "output_buffer_timeout": 250,
    "tls_v1": false,
    "deflate": false,
    "snappy": false,
    "sample_rate": 0,
    "user_agent": "erwind/0.1.0"
}

响应: "OK" 或 JSON 配置
```

#### 2. AUTH

```
命令行: "AUTH\n"
数据: 4 字节 secret 长度 + secret body

响应: "OK" 或权限 JSON
```

#### 3. SUB (Subscribe)

```
命令行: "SUB <topic_name> <channel_name>\n"

参数:
- topic_name: 字母数字+下划线，长度 1-32
- channel_name: 字母数字+下划线，长度 1-32，可带 "#ephemeral" 后缀

响应: "OK"
错误: E_INVALID, E_BAD_TOPIC, E_BAD_CHANNEL
```

#### 4. PUB (Publish)

```
命令行: "PUB <topic_name>\n"
数据: 4 字节 body 长度 + message body

响应: "OK"
错误: E_INVALID, E_BAD_TOPIC, E_TOPIC_EXITING, E_PUB_FAILED
```

#### 5. MPUB (Multi Publish)

```
命令行: "MPUB <topic_name>\n"
数据: 4 字节 body 长度 + 消息数量 + 各消息长度和数据

格式:
[4 bytes: total body size]
[4 bytes: number of messages]
[
  [4 bytes: message #1 length]
  [message #1 data]
  ...
]

响应: "OK"
```

#### 6. DPUB (Deferred Publish)

```
命令行: "DPUB <topic_name> <defer_time_ms>\n"
数据: 4 字节 body 长度 + message body

响应: "OK"
```

#### 7. RDY (Ready)

```
命令行: "RDY <count>\n"

参数:
- count: 0 到 最大 RDY（默认 2500）

说明: 更新消费者的 ready 计数，用于流量控制
```

#### 8. FIN (Finish)

```
命令行: "FIN <message_id>\n"

说明: 标记消息处理完成，从 in-flight 队列移除
错误: E_INVALID, E_FIN_FAILED
```

#### 9. REQ (Requeue)

```
命令行: "REQ <message_id> <timeout_ms>\n"

参数:
- timeout_ms: 延迟时间（毫秒），-1 表示使用默认超时

说明: 消息重新入队，延迟后再次投递
错误: E_INVALID, E_REQ_FAILED
```

#### 10. TOUCH

```
命令行: "TOUCH <message_id>\n"

说明: 延长消息超时时间
错误: E_INVALID, E_TOUCH_FAILED
```

#### 11. CLS (Close)

```
命令行: "CLS\n"

说明: 优雅关闭，等待 in-flight 消息完成
响应: "CLOSE_WAIT"，然后关闭连接
```

#### 12. NOP

```
命令行: "NOP\n"

说明: 心跳响应，无操作
```

## Erlang 实现

### 数据结构

```erlang
-module(erwind_protocol).

%% 帧类型定义
-define(FRAME_TYPE_RESPONSE, 0).
-define(FRAME_TYPE_ERROR, 1).
-define(FRAME_TYPE_MESSAGE, 2).

%% 错误码定义
-define(E_INVALID, <<"E_INVALID">>).
-define(E_BAD_TOPIC, <<"E_BAD_TOPIC">>).
-define(E_BAD_CHANNEL, <<"E_BAD_CHANNEL">>).
-define(E_BAD_BODY, <<"E_BAD_BODY">>).
-define(E_REQ_FAILED, <<"E_REQ_FAILED">>).
-define(E_FIN_FAILED, <<"E_FIN_FAILED">>).
-define(E_PUB_FAILED, <<"E_PUB_FAILED">>).
-define(E_MPUB_FAILED, <<"E_MPUB_FAILED">>).
-define(E_AUTH_FAILED, <<"E_AUTH_FAILED">>).
-define(E_UNAUTHORIZED, <<"E_UNAUTHORIZED">>).
-define(E_SUB_FAILED, <<"E_SUB_FAILED">>).
-define(E_ALREADY_SUBSCRIBED, <<"E_ALREADY_SUBSCRIBED">>).
-define(E_NOT_SUBSCRIBED, <<"E_NOT_SUBSCRIBED">>).
-define(E_TOUCH_FAILED, <<"E_TOUCH_FAILED">>).
-define(E_TOPIC_EXITING, <<"E_TOPIC_EXITING">>).
-define(E_CHANNEL_EXITING, <<"E_CHANNEL_EXITING">>).

%% 消息记录
-record(nsq_message, {
    id :: binary(),           %% 16 字节 hex 字符串
    timestamp :: integer(),   %% 毫秒时间戳
    attempts :: integer(),    %% 投递次数
    body :: binary()          %% 消息体
}).

%% 命令记录
-record(cmd_identify, {params :: map()}).
-record(cmd_auth, {secret :: binary()}).
-record(cmd_sub, {topic :: binary(), channel :: binary()}).
-record(cmd_pub, {topic :: binary(), body :: binary()}).
-record(cmd_mpub, {topic :: binary(), messages :: [binary()]}).
-record(cmd_dpub, {topic :: binary(), defer :: integer(), body :: binary()}).
-record(cmd_rdy, {count :: integer()}).
-record(cmd_fin, {msg_id :: binary()}).
-record(cmd_req, {msg_id :: binary(), timeout :: integer()}).
-record(cmd_touch, {msg_id :: binary()}).
-record(cmd_cls, {}).
-record(cmd_nop, {}).
```

### 编解码函数

```erlang
%% 编码响应帧
-spec encode_response(binary()) -> binary().
encode_response(Body) ->
    FrameType = <<?FRAME_TYPE_RESPONSE:32/big>>,
    Length = <<(byte_size(Body)):32/big>>,
    <<FrameType/binary, Length/binary, Body/binary>>.

%% 编码错误帧
-spec encode_error(binary()) -> binary().
encode_error(ErrorCode) ->
    FrameType = <<?FRAME_TYPE_ERROR:32/big>>,
    Length = <<(byte_size(ErrorCode)):32/big>>,
    <<FrameType/binary, Length/binary, ErrorCode/binary>>.

%% 编码消息帧
-spec encode_message(#nsq_message{}) -> binary().
encode_message(#nsq_message{id = Id, timestamp = Ts, attempts = Att, body = Body}) ->
    FrameType = <<?FRAME_TYPE_MESSAGE:32/big>>,
    TsBin = <<Ts:64/big>>,
    AttBin = <<Att:16/big>>,
    MsgBin = <<TsBin/binary, AttBin/binary, Id/binary, Body/binary>>,
    Length = <<(byte_size(MsgBin)):32/big>>,
    <<FrameType/binary, Length/binary, MsgBin/binary>>.

%% 解码帧
-spec decode_frame(binary()) -> {ok, {response | error | message, binary()}, binary()} | incomplete.
decode_frame(<<FrameType:32/big, Length:32/big, Rest/binary>>) when byte_size(Rest) >= Length ->
    <<Body:Length/binary, Remaining/binary>> = Rest,
    Type = case FrameType of
        ?FRAME_TYPE_RESPONSE -> response;
        ?FRAME_TYPE_ERROR -> error;
        ?FRAME_TYPE_MESSAGE -> message
    end,
    {ok, {Type, Body}, Remaining};
decode_frame(_) ->
    incomplete.
```

### 命令解析

```erlang
%% 解析命令（从 TCP 流）
-spec parse_command(binary()) -> {ok, tuple(), binary()} | incomplete | {error, term()}.
parse_command(Data) ->
    case binary:split(Data, <<"\n">>) of
        [Line, Rest] ->
            case parse_line(Line) of
                {needs_body, Cmd, Size} when Size > 0 ->
                    case Rest of
                        <<Body:Size/binary, Remaining/binary>> ->
                            {ok, complete_command(Cmd, Body), Remaining};
                        _ ->
                            incomplete
                    end;
                {ok, Cmd} ->
                    {ok, Cmd, Rest};
                {error, Reason} ->
                    {error, Reason}
            end;
        [_] ->
            incomplete
    end.

%% 解析命令行
parse_line(<<"IDENTIFY">>) ->
    {needs_body, identify, 4};  %% 读取 4 字节长度
parse_line(<<"AUTH">>) ->
    {needs_body, auth, 4};
parse_line(<<"SUB ", Rest/binary>>) ->
    case binary:split(Rest, <<" ">>) of
        [Topic, Channel] -> {ok, #cmd_sub{topic = Topic, channel = Channel}};
        _ -> {error, invalid_sub}
    end;
parse_line(<<"PUB ", Topic/binary>>) ->
    {needs_body, {pub, Topic}, 4};
parse_line(<<"MPUB ", Topic/binary>>) ->
    {needs_body, {mpub, Topic}, 4};
parse_line(<<"DPUB ", Rest/binary>>) ->
    case binary:split(Rest, <<" ">>) of
        [Topic, Defer] ->
            {needs_body, {dpub, Topic, binary_to_integer(Defer)}, 4};
        _ ->
            {error, invalid_dpub}
    end;
parse_line(<<"RDY ", Count/binary>>) ->
    {ok, #cmd_rdy{count = binary_to_integer(Count)}};
parse_line(<<"FIN ", MsgId/binary>>) ->
    {ok, #cmd_fin{msg_id = MsgId}};
parse_line(<<"REQ ", Rest/binary>>) ->
    case binary:split(Rest, <<" ">>) of
        [MsgId, Timeout] ->
            {ok, #cmd_req{msg_id = MsgId, timeout = binary_to_integer(Timeout)}};
        _ ->
            {error, invalid_req}
    end;
parse_line(<<"TOUCH ", MsgId/binary>>) ->
    {ok, #cmd_touch{msg_id = MsgId}};
parse_line(<<"CLS">>) ->
    {ok, #cmd_cls{}};
parse_line(<<"NOP">>) ->
    {ok, #cmd_nop{}};
parse_line(_) ->
    {error, unknown_command}.

%% 完成带 body 的命令
complete_command(identify, Body) ->
    <<Size:32/big, JsonBody:Size/binary>> = Body,
    #cmd_identify{params = jsx:decode(JsonBody, [return_maps])};
complete_command({pub, Topic}, Body) ->
    <<Size:32/big, MsgBody:Size/binary>> = Body,
    #cmd_pub{topic = Topic, body = MsgBody};
complete_command({mpub, Topic}, Body) ->
    <<Size:32/big, Messages/binary>> = Body,
    #cmd_mpub{topic = Topic, messages = parse_mpub_messages(Messages)}.

%% 解析 MPUB 消息列表
parse_mpub_messages(<<Count:32/big, Rest/binary>>) ->
    parse_mpub_messages(Rest, Count, []).

parse_mpub_messages(_, 0, Acc) ->
    lists:reverse(Acc);
parse_mpub_messages(<<Size:32/big, Msg:Size/binary, Rest/binary>>, Count, Acc) ->
    parse_mpub_messages(Rest, Count - 1, [Msg | Acc]).
```

### 消息 ID 生成

```erlang
%% 生成唯一消息 ID（16 字节 hex）
-spec generate_msg_id() -> binary().
generate_msg_id() ->
    <<Time:48/big, Seq:16/big, NodeId:32/big, Rand:16/big>> =
        <<(erlang:system_time(millisecond)):48,
          (get_sequence()):16,
          (get_node_id()):32,
          (rand:uniform(65536)):16>>,
    bin_to_hex(<<Time:48, Seq:16, NodeId:32, Rand:16>>).

bin_to_hex(Bin) ->
    << <<(hex(N)), (hex(N2))>> || <<N:4, N2:4>> <= Bin >>.

hex(N) when N < 10 -> $0 + N;
hex(N) -> $a + N - 10.
```

## 依赖关系

### 依赖的模块
- `jsx` 或 `jsone` - JSON 编解码

### 被依赖的模块
- `erwind_tcp_listener` - 协议模块被 TCP 监听器使用
- `erwind_channel` - 编码消息推送给消费者

## 接口定义

```erlang
%% 编码/解码
-export([encode_response/1, encode_error/1, encode_message/1,
         decode_frame/1, parse_command/1]).

%% 工具函数
-export([generate_msg_id/0, validate_topic/1, validate_channel/1]).

%% 类型定义
-type frame_type() :: response | error | message.
-type nsq_command() :: #cmd_identify{} | #cmd_sub{} | #cmd_pub{} | ...
```
