%% erwind_protocol.erl
%% NSQ TCP Protocol V2 - 编解码模块
%% 负责协议帧的编码/解码和命令解析

-module(erwind_protocol).

%% API
-export([encode_response/1, encode_error/1, encode_message/1,
         decode_frame/1, parse_command/1, parse_frame/1]).

%% Utility functions
-export([generate_msg_id/0, validate_topic/1, validate_channel/1,
         parse_json/1, encode_json/1]).

%% Export for testing
-export([parse_line_with_body/2, parse_body/2, parse_integer/1]).

-include_lib("../include/erwind.hrl").

%% =============================================================================
%% Frame Encoding
%% =============================================================================

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
    %% Message format: [timestamp:8][attempts:2][id:16][body:N]
    TsBin = <<Ts:64/big>>,
    AttBin = <<Att:16/big>>,
    MsgBin = <<TsBin/binary, AttBin/binary, Id/binary, Body/binary>>,
    Length = <<(byte_size(MsgBin)):32/big>>,
    <<FrameType/binary, Length/binary, MsgBin/binary>>.

%% =============================================================================
%% Frame Decoding
%% =============================================================================

%% 解码帧
-spec decode_frame(binary()) ->
    {ok, {response | error | message, binary()}, binary()} | incomplete.
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

%% 解析完整帧（用于测试）
-spec parse_frame(binary()) -> {ok, tuple()} | incomplete | {error, term()}.
parse_frame(Data) ->
    case decode_frame(Data) of
        {ok, {Type, Body}, _} ->
            {ok, {Type, Body}};
        incomplete ->
            incomplete
    end.

%% =============================================================================
%% Command Parsing
%% =============================================================================

%% 解析命令（从 TCP 流）
%% NSQ 协议格式：
%%   - 简单命令: "CMD\n"
%%   - 带 body 的命令: "CMD\n" + 4字节长度(big endian) + body
-spec parse_command(binary()) ->
    {ok, tuple(), binary()} | {incomplete, binary()} | {error, term()}.
parse_command(Buffer) ->
    case binary:split(Buffer, <<"\n">>) of
        [Line, Rest] ->
            parse_line_with_body(Line, Rest);
        [_] ->
            %% 数据不完整，等待更多数据
            {incomplete, Buffer}
    end.

%% 解析命令行并根据需要读取 body
parse_line_with_body(Line, Rest) ->
    Result = case binary:split(Line, <<" ">>, [global]) of
        [<<"IDENTIFY">>] ->
            %% IDENTIFY: 4字节长度 + JSON body
            parse_body(Rest, fun(Body, Remain) -> {ok, {identify, Body}, Remain} end);

        [<<"AUTH">>] ->
            %% AUTH: 4字节长度 + secret body
            parse_body(Rest, fun(Body, Remain) -> {ok, {auth, Body}, Remain} end);

        [<<"SUB">>, Topic, Channel] ->
            {ok, {sub, Topic, Channel}, Rest};

        [<<"PUB">>, Topic] ->
            %% PUB: 4字节长度 + message body
            parse_body(Rest, fun(Body, Remain) -> {ok, {pub, Topic, Body}, Remain} end);

        [<<"MPUB">>, Topic] ->
            %% MPUB: 4字节长度 + messages body
            parse_body(Rest, fun(Body, Remain) -> {ok, {mpub, Topic, Body}, Remain} end);

        [<<"DPUB">>, Topic, DeferBin] ->
            %% DPUB: 4字节长度 + message body
            case parse_integer(DeferBin) of
                {ok, DeferMs} ->
                    parse_body(Rest, fun(Body, Remain) ->
                        {ok, {dpub, Topic, DeferMs, Body}, Remain}
                    end);
                error ->
                    {error, ?E_INVALID}
            end;

        [<<"RDY">>, CountBin] ->
            case parse_integer(CountBin) of
                {ok, Count} -> {ok, {rdy, Count}, Rest};
                error -> {error, ?E_INVALID}
            end;

        [<<"FIN">>, MsgId] ->
            {ok, {fin, MsgId}, Rest};

        [<<"REQ">>, MsgId, TimeoutBin] ->
            case parse_integer(TimeoutBin) of
                {ok, Timeout} -> {ok, {req, MsgId, Timeout}, Rest};
                error -> {ok, {req, MsgId, 0}, Rest}
            end;

        [<<"TOUCH">>, MsgId] ->
            {ok, {touch, MsgId}, Rest};

        [<<"CLS">>] ->
            {ok, cls, Rest};

        [<<"NOP">>] ->
            {ok, nop, Rest};

        _ ->
            {error, ?E_INVALID}
    end,
    %% Convert {error, _} to proper format
    case Result of
        {error, Reason} -> {error, Reason};
        _ -> Result
    end.

%% 解析 body（4字节长度前缀 + body）
parse_body(Buffer, ContinueFn) ->
    case Buffer of
        <<Size:32/big, BodyAndRest/binary>> when byte_size(BodyAndRest) >= Size ->
            <<Body:Size/binary, Rest/binary>> = BodyAndRest,
            ContinueFn(Body, Rest);
        _ ->
            %% 数据不完整
            {incomplete, Buffer}
    end.

%% 解析整数
parse_integer(Bin) ->
    try
        {ok, binary_to_integer(Bin)}
    catch
        _:_ -> error
    end.

%% =============================================================================
%% Message ID Generation
%% =============================================================================

%% 生成唯一消息 ID（16 字节 hex）
%% 格式: [时间戳:48][序列号:16][节点ID:32][随机数:32]
-spec generate_msg_id() -> binary().
generate_msg_id() ->
    Time = erlang:system_time(millisecond),
    Seq = get_sequence(),
    NodeId = get_node_id(),
    Rand = rand:uniform(4294967296) - 1,
    Bin = <<Time:48/big, Seq:16/big, NodeId:32/big, Rand:32/big>>,
    bin_to_hex(Bin).

%% 获取序列号（每毫秒递增）
get_sequence() ->
    Key = {erwind_msg_seq, erlang:system_time(millisecond)},
    case get(Key) of
        undefined ->
            put(Key, 1),
            0;
        N when is_integer(N) ->
            put(Key, N + 1),
            N
    end.

%% 获取节点 ID（基于节点名哈希）
get_node_id() ->
    Node = node(),
    erlang:phash2(Node, 4294967296).

%% 二进制转 hex 字符串
bin_to_hex(Bin) ->
    << <<(hex(N1)), (hex(N2))>> || <<N1:4, N2:4>> <= Bin >>.

hex(N) when N < 10 -> $0 + N;
hex(N) -> $a + N - 10.

%% =============================================================================
%% Validation Functions
%% =============================================================================

%% 验证 topic 名称
%% 规则: 字母数字+下划线+连字符+点号，长度 1-32，不能以点号结尾
-spec validate_topic(binary()) -> ok | {error, binary()}.
validate_topic(Topic) when byte_size(Topic) < 1; byte_size(Topic) > 32 ->
    {error, ?E_BAD_TOPIC};
validate_topic(Topic) ->
    case binary:last(Topic) of
        $. -> {error, ?E_BAD_TOPIC};
        _ -> validate_topic_chars(Topic)
    end.

validate_topic_chars(<<>>) -> ok;
validate_topic_chars(<<C, Rest/binary>>) ->
    case is_valid_topic_char(C) of
        true -> validate_topic_chars(Rest);
        false -> {error, ?E_BAD_TOPIC}
    end.

is_valid_topic_char(C) when C >= $a, C =< $z -> true;
is_valid_topic_char(C) when C >= $A, C =< $Z -> true;
is_valid_topic_char(C) when C >= $0, C =< $9 -> true;
is_valid_topic_char(C) when C =:= $_; C =:= $-; C =:= $. -> true;
is_valid_topic_char(_) -> false.

%% 验证 channel 名称
%% 规则: 类似 topic，可带 "#ephemeral" 后缀
-spec validate_channel(binary()) -> ok | {error, binary()}.
validate_channel(Channel) ->
    case binary:split(Channel, <<"#ephemeral">>) of
        [BaseChannel, <<>>] ->
            %% Has ephemeral suffix, validate base
            validate_topic(BaseChannel);
        _ ->
            %% No suffix or invalid format, validate as topic
            validate_topic(Channel)
    end.

%% =============================================================================
%% JSON Functions (simple implementation, no external deps)
%% =============================================================================

%% 简单 JSON 解析（仅支持 IDENTIFY 需要的字段）
-spec parse_json(binary()) -> {ok, map()} | {error, term()}.
parse_json(Bin) ->
    try
        {ok, parse_json_object(Bin)}
    catch
        _:_ -> {error, invalid_json}
    end.

%% 简单的 JSON 对象解析器
parse_json_object(Bin) ->
    %% 去除首尾空格和大括号
    Trimmed = binary:replace(Bin, [<<" ">>, <<"\n">>, <<"\r">>, <<"\t">>], <<>>, [global]),
    case Trimmed of
        <<"{", Content/binary>> ->
            Size = byte_size(Content),
            case Content of
                <<Inner:(Size-1)/binary, "}">> when Size > 1 ->
                    parse_json_pairs(Inner, #{});
                _ ->
                    #{}
            end;
        <<>> ->
            #{};
        _ ->
            %% 如果不是对象，尝试解析为值
            parse_json_value(Trimmed)
    end.

parse_json_pairs(<<>>, Acc) ->
    Acc;
parse_json_pairs(Bin, Acc) ->
    %% 找到键值对
    case binary:split(Bin, <<":">>) of
        [KeyPart, Rest] ->
            Key = parse_json_string(KeyPart),
            {Value, Remaining} = parse_json_value(Rest),
            NewAcc = maps:put(Key, Value, Acc),
            %% 检查是否有更多键值对 - 跳过开头的逗号
            More = case Remaining of
                <<",", Rest2/binary>> -> Rest2;
                _ -> Remaining
            end,
            case More of
                <<>> -> NewAcc;
                _ -> parse_json_pairs(More, NewAcc)
            end;
        [_] ->
            Acc
    end.

parse_json_string(Bin) ->
    %% 去除引号
    Trimmed = binary:replace(Bin, <<"\"">>, <<>>, [global]),
    binary:replace(Trimmed, <<"\\">>, <<>>, [global]).

parse_json_value(<<"\"", Rest/binary>>) ->
    %% 字符串值
    case binary:split(Rest, <<"\"">>) of
        [Value, Remaining] -> {Value, Remaining};
        [Value] -> {Value, <<>>}
    end;
parse_json_value(Bin) ->
    %% 数字或布尔值
    case binary:split(Bin, <<",">>) of
        [Part, Remaining] ->
            {parse_json_number(Part), Remaining};
        [Part] ->
            {parse_json_number(Part), <<>>}
    end.

parse_json_number(Bin) ->
    Str = binary_to_list(Bin),
    case string:to_integer(Str) of
        {Int, []} -> Int;
        _ ->
            case string:to_float(Str) of
                {Float, []} -> Float;
                _ ->
                    %% 布尔值
                    case Str of
                        "true" -> true;
                        "false" -> false;
                        "null" -> null;
                        _ -> Bin
                    end
            end
    end.

%% 编码简单值为 JSON
-spec encode_json(term()) -> binary().
encode_json(true) -> <<"true">>;
encode_json(false) -> <<"false">>;
encode_json(null) -> <<"null">>;
encode_json(N) when is_integer(N) -> integer_to_binary(N);
encode_json(N) when is_float(N) -> float_to_binary(N);
encode_json(Bin) when is_binary(Bin) ->
    <<$", Bin/binary, $">>;
encode_json(Map) when is_map(Map) ->
    Pairs = maps:fold(fun(Key, Val, Acc) when is_binary(Key) ->
        EncodedVal = encode_json(Val),
        Pair = <<$", Key/binary, $", $:, EncodedVal/binary>>,
        [Pair | Acc]
    end, [], Map),
    <<${, (binary_join(lists:reverse(Pairs), <<$,>>))/binary, $}>>.

binary_join([], _Sep) -> <<>>;
binary_join([H], _Sep) -> H;
binary_join([H|T], Sep) ->
    <<H/binary, Sep/binary, (binary_join(T, Sep))/binary>>.
