%% erwind_connection.erl
%% 连接处理器 - gen_statem 实现 NSQ 协议状态机

-module(erwind_connection).
-behaviour(gen_statem).

%% API
-export([start_link/1, activate/1, stop/1]).
-export([deliver_message/2]).

%% Export for testing
-export([parse_command/1]).

%% gen_statem callbacks
-export([callback_mode/0, init/1, terminate/3, code_change/4]).

%% State callbacks
-export([wait_identify/3, authenticated/3, subscribed/3, closing/3]).

-include_lib("erwind/include/erwind.hrl").

%% 状态数据
-record(conn_data, {
    socket :: inet:socket() | undefined,
    peer :: {inet:ip_address(), inet:port_number()} | inet:returned_non_ip_address() | undefined,

    %% 客户端信息
    client_id :: binary() | undefined,
    hostname :: binary() | undefined,
    features = #{} :: map(),

    %% 订阅信息
    subscribed = false :: boolean(),
    topic :: binary() | undefined,
    channel :: binary() | undefined,

    %% 流控制
    rdy_count = 0 :: integer(),
    in_flight = #{} :: #{binary() => #nsq_message{}},
    max_rdy = ?DEFAULT_MAX_RDY :: integer(),
    msg_timeout = ?DEFAULT_MSG_TIMEOUT :: integer(),

    %% 心跳
    heartbeat_ref :: reference() | undefined,
    heartbeat_interval = ?DEFAULT_HEARTBEAT_INTERVAL :: integer(),

    %% 缓冲区
    recv_buffer = <<>> :: binary()
}).

%% =============================================================================
%% API
%% =============================================================================

%% 启动连接处理器
-spec start_link(Socket :: inet:socket()) -> gen_statem:start_ret().
start_link(Socket) ->
    gen_statem:start_link(?MODULE, [Socket], []).

%% 激活连接（socket 控制权转移完成后调用）
-spec activate(Pid :: pid()) -> ok.
activate(Pid) ->
    gen_statem:cast(Pid, activate).

%% 停止连接
-spec stop(Pid :: pid()) -> ok.
stop(Pid) ->
    gen_statem:stop(Pid).

%% 投递消息给消费者
-spec deliver_message(pid(), #nsq_message{}) -> ok.
deliver_message(Pid, Msg) ->
    gen_statem:cast(Pid, {deliver_message, Msg}).

%% =============================================================================
%% gen_statem callbacks
%% =============================================================================

callback_mode() ->
    state_functions.

init([Socket]) ->
    {ok, PeerAddr} = inet:peername(Socket),
    %% PeerAddr can be {ip_address(), port()} or returned_non_ip_address() like {local, binary()}
    Data = #conn_data{socket = Socket, peer = PeerAddr},
    {ok, wait_identify, Data, [{state_timeout, ?IDENTIFY_TIMEOUT, identify_timeout}]}.

terminate(_Reason, _State, #conn_data{socket = Socket, heartbeat_ref = HbRef}) ->
    %% 取消心跳定时器
    case HbRef of
        undefined -> ok;
        _ -> erlang:cancel_timer(HbRef)
    end,

    %% 关闭 socket
    case Socket of
        undefined -> ok;
        _ -> gen_tcp:close(Socket)
    end,

    %% 从连接表中移除
    try ets:delete(erwind_connections, self())
    catch _:_ -> ok
    end,
    ok.

code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.

%% =============================================================================
%% State: wait_identify - 等待客户端发送 IDENTIFY
%% =============================================================================

wait_identify(enter, _OldState, _Data) ->
    keep_state_and_data;

wait_identify(state_timeout, identify_timeout, #conn_data{socket = Socket} = Data) ->
    send_error(Socket, <<"E_IDENTIFY_TIMEOUT">>),
    {stop, normal, Data};

wait_identify(cast, activate, #conn_data{socket = Socket}) ->
    %% 激活 socket 接收
    inet:setopts(Socket, [{active, once}]),
    keep_state_and_data;

wait_identify(info, {tcp, Socket, RawData}, #conn_data{socket = Socket, recv_buffer = Buf} = Data) ->
    NewBuf = <<Buf/binary, RawData/binary>>,
    case parse_command(NewBuf) of
        {incomplete, Rest} ->
            inet:setopts(Socket, [{active, once}]),
            {keep_state, Data#conn_data{recv_buffer = Rest}};

        {{identify, Body}, Rest} ->
            case parse_identify_params(Body) of
                {ok, Params} ->
                    case validate_identify(Params, Data) of
                        {ok, NewData} ->
                            send_response(Socket, <<"OK">>),
                            %% 启动心跳
                            HbData = start_heartbeat(NewData),
                            inet:setopts(Socket, [{active, once}]),
                            {next_state, authenticated, HbData#conn_data{recv_buffer = Rest}};
                        {error, Reason} ->
                            send_error(Socket, Reason),
                            {stop, normal, Data}
                    end;
                {error, _Reason} ->
                    send_error(Socket, ?E_INVALID),
                    inet:setopts(Socket, [{active, once}]),
                    {keep_state, Data#conn_data{recv_buffer = Rest}}
            end;

        {_Cmd, Rest} ->
            %% 必须先发送 IDENTIFY
            send_error(Socket, <<"E_IDENTIFY_REQUIRED">>),
            inet:setopts(Socket, [{active, once}]),
            {keep_state, Data#conn_data{recv_buffer = Rest}}
    end;

wait_identify(info, {tcp_closed, _Socket}, Data) ->
    {stop, normal, Data};

wait_identify(info, {tcp_error, _Socket, _Reason}, Data) ->
    {stop, normal, Data};

wait_identify(EventType, EventContent, Data) ->
    handle_common_event(EventType, EventContent, wait_identify, Data).

%% =============================================================================
%% State: authenticated - 已认证，等待命令
%% =============================================================================

authenticated(enter, _OldState, _Data) ->
    keep_state_and_data;

authenticated(cast, heartbeat_tick, #conn_data{socket = Socket} = Data) ->
    %% 发送心跳请求 (HEARTBEAT 帧)
    send_heartbeat(Socket),
    %% 设置下一次心跳
    NewData = start_heartbeat(Data),
    {keep_state, NewData};

authenticated(cast, activate, _Data) ->
    keep_state_and_data;

authenticated(info, {tcp, Socket, RawData}, #conn_data{socket = Socket, recv_buffer = Buf} = Data) ->
    NewBuf = <<Buf/binary, RawData/binary>>,
    process_commands(NewBuf, Data);

authenticated(info, {tcp_closed, _Socket}, Data) ->
    {stop, normal, Data};

authenticated(info, {tcp_error, _Socket, _Reason}, Data) ->
    {stop, normal, Data};

authenticated(EventType, EventContent, Data) ->
    handle_common_event(EventType, EventContent, authenticated, Data).

%% =============================================================================
%% State: subscribed - 消费者已订阅
%% =============================================================================

subscribed(enter, _OldState, _Data) ->
    keep_state_and_data;

subscribed(cast, heartbeat_tick, #conn_data{socket = Socket} = Data) ->
    send_heartbeat(Socket),
    %% 设置下一次心跳
    NewData = start_heartbeat(Data),
    {keep_state, NewData};

subscribed(cast, {deliver_message, Msg}, #conn_data{socket = Socket, rdy_count = RDY} = Data) when RDY > 0 ->
    %% 投递消息
    send_message(Socket, Msg),

    %% 更新状态
    NewInFlight = maps:put(Msg#nsq_message.id, Msg, Data#conn_data.in_flight),
    NewRDY = RDY - 1,

    {keep_state, Data#conn_data{rdy_count = NewRDY, in_flight = NewInFlight}};

subscribed(cast, {deliver_message, _Msg}, _Data) ->
    %% RDY 为 0，无法投递
    keep_state_and_data;

subscribed(cast, activate, _Data) ->
    keep_state_and_data;

subscribed(info, {tcp, Socket, RawData}, #conn_data{socket = Socket, recv_buffer = Buf} = Data) ->
    NewBuf = <<Buf/binary, RawData/binary>>,
    process_commands(NewBuf, Data);

subscribed(info, {tcp_closed, _Socket}, Data) ->
    {stop, normal, Data};

subscribed(info, {tcp_error, _Socket, _Reason}, Data) ->
    {stop, normal, Data};

subscribed(EventType, EventContent, Data) ->
    handle_common_event(EventType, EventContent, subscribed, Data).

%% =============================================================================
%% State: closing - 正在关闭
%% =============================================================================

closing(enter, _OldState, _Data) ->
    keep_state_and_data;

closing(info, {tcp_closed, _Socket}, Data) ->
    {stop, normal, Data};

closing(info, {tcp_error, _Socket, _Reason}, Data) ->
    {stop, normal, Data};

closing(EventType, EventContent, Data) ->
    handle_common_event(EventType, EventContent, closing, Data).

%% =============================================================================
%% Internal functions
%% =============================================================================

%% 处理通用事件
handle_common_event(info, {tcp, Socket, RawData}, _State, #conn_data{socket = Socket, recv_buffer = Buf} = Data) ->
    NewBuf = <<Buf/binary, RawData/binary>>,
    inet:setopts(Socket, [{active, once}]),
    {keep_state, Data#conn_data{recv_buffer = NewBuf}};

handle_common_event(info, {tcp_closed, _Socket}, _State, Data) ->
    {stop, normal, Data};

handle_common_event(info, {tcp_error, _Socket, _Reason}, _State, Data) ->
    {stop, normal, Data};

handle_common_event(_EventType, _EventContent, _State, _Data) ->
    keep_state_and_data.

%% 处理命令
process_commands(Buffer, #conn_data{socket = Socket} = Data) when Socket =/= undefined ->
    case parse_command(Buffer) of
        {incomplete, Rest} ->
            inet:setopts(Socket, [{active, once}]),
            {keep_state, Data#conn_data{recv_buffer = Rest}};

        {Cmd, Rest} ->
            case execute_command(Cmd, Data) of
                {keep_state, NewData} ->
                    process_commands(Rest, NewData);
                {next_state, NewState, NewData} ->
                    inet:setopts(Socket, [{active, once}]),
                    {next_state, NewState, NewData#conn_data{recv_buffer = Rest}};
                {stop, Reason, NewData} ->
                    {stop, Reason, NewData}
            end
    end;

process_commands(_Buffer, Data) ->
    %% Socket is undefined, stop the connection
    {stop, normal, Data}.

%% 执行命令
execute_command({pub, Topic, Body}, Data) ->
    handle_publish(Topic, Body, Data);

execute_command({mpub, Topic, Body}, Data) ->
    handle_mpublish(Topic, Body, Data);

execute_command({dpub, Topic, DeferMs, Body}, Data) ->
    handle_deferred_publish(Topic, DeferMs, Body, Data);

execute_command({sub, Topic, Channel}, Data) ->
    handle_subscribe(Topic, Channel, Data);

execute_command({rdy, Count}, Data) ->
    handle_ready(Count, Data);

execute_command({fin, MsgId}, Data) ->
    handle_finish(MsgId, Data);

execute_command({req, MsgId, Timeout}, Data) ->
    handle_requeue(MsgId, Timeout, Data);

execute_command({touch, MsgId}, Data) ->
    handle_touch(MsgId, Data);

execute_command({auth, Secret}, Data) ->
    handle_auth(Secret, Data);

execute_command(cls, Data) ->
    handle_close(Data);

execute_command(nop, Data) ->
    %% NOP - 心跳响应，无需操作
    {keep_state, Data};

execute_command(identify, #conn_data{socket = Socket} = Data) ->
    send_error(Socket, <<"E_ALREADY_IDENTIFIED">>),
    {keep_state, Data};

execute_command({error, Reason}, #conn_data{socket = Socket} = Data) ->
    send_error(Socket, Reason),
    {keep_state, Data};

execute_command(_, #conn_data{socket = Socket} = Data) ->
    send_error(Socket, ?E_INVALID),
    {keep_state, Data}.

%% =============================================================================
%% Command handlers
%% =============================================================================

handle_publish(Topic, Body, #conn_data{socket = Socket} = Data) ->
    %% TODO: 调用 erwind_topic:publish(Topic, Body)
    logger:info("PUB topic=~s body_size=~p~n", [Topic, byte_size(Body)]),

    %% 临时模拟成功响应
    send_response(Socket, <<"OK">>),
    {keep_state, Data}.

handle_mpublish(Topic, Messages, #conn_data{socket = Socket} = Data) ->
    logger:info("MPUB topic=~s count=~p~n", [Topic, length(Messages)]),

    %% TODO: 批量发布消息
    send_response(Socket, <<"OK">>),
    {keep_state, Data}.

handle_deferred_publish(Topic, DeferMs, Body, #conn_data{socket = Socket} = Data) ->
    logger:info("DPUB topic=~s defer=~p body_size=~p~n", [Topic, DeferMs, byte_size(Body)]),

    %% TODO: 延迟发布消息
    send_response(Socket, <<"OK">>),
    {keep_state, Data}.

handle_subscribe(Topic, Channel, #conn_data{socket = Socket, subscribed = false} = Data) ->
    logger:info("SUB topic=~s channel=~s~n", [Topic, Channel]),

    %% TODO: 调用 erwind_channel:subscribe(Topic, Channel, self())

    %% 发送 OK 响应
    send_response(Socket, <<"OK">>),

    %% 转换到 subscribed 状态
    {next_state, subscribed, Data#conn_data{
        subscribed = true,
        topic = Topic,
        channel = Channel
    }};

handle_subscribe(_Topic, _Channel, #conn_data{socket = Socket} = Data) ->
    send_error(Socket, ?E_ALREADY_SUBSCRIBED),
    {keep_state, Data}.

handle_ready(Count, #conn_data{socket = Socket, subscribed = true, max_rdy = MaxRDY} = Data) when Count > MaxRDY ->
    send_error(Socket, <<"E_INVALID_RDY">>),
    {keep_state, Data};

handle_ready(Count, #conn_data{socket = Socket, subscribed = true} = Data) when Count >= 0 ->
    logger:info("RDY count=~p~n", [Count]),

    NewData = Data#conn_data{rdy_count = Count},

    %% 发送 OK 响应
    send_response(Socket, <<"OK">>),

    %% TODO: 触发消息投递
    %% maybe_deliver_messages(NewData)

    {keep_state, NewData};

handle_ready(_Count, #conn_data{socket = Socket} = Data) ->
    send_error(Socket, ?E_SUB_FAILED),
    {keep_state, Data}.

handle_finish(MsgId, #conn_data{socket = Socket, subscribed = true, in_flight = InFlight} = Data) ->
    case maps:is_key(MsgId, InFlight) of
        true ->
            logger:info("FIN msg_id=~s~n", [MsgId]),

            %% TODO: 调用 erwind_channel:finish(MsgId)

            NewInFlight = maps:remove(MsgId, InFlight),
            send_response(Socket, <<"OK">>),
            {keep_state, Data#conn_data{in_flight = NewInFlight}};
        false ->
            send_error(Socket, ?E_FIN_FAILED),
            {keep_state, Data}
    end;

handle_finish(_MsgId, #conn_data{socket = Socket} = Data) ->
    send_error(Socket, ?E_FIN_FAILED),
    {keep_state, Data}.

handle_requeue(MsgId, Timeout, #conn_data{socket = Socket, subscribed = true, in_flight = InFlight} = Data) ->
    case maps:is_key(MsgId, InFlight) of
        true ->
            logger:info("REQ msg_id=~s timeout=~p~n", [MsgId, Timeout]),

            %% TODO: 调用 erwind_channel:requeue(MsgId, Timeout)

            NewInFlight = maps:remove(MsgId, InFlight),
            send_response(Socket, <<"OK">>),
            {keep_state, Data#conn_data{in_flight = NewInFlight}};
        false ->
            send_error(Socket, ?E_REQ_FAILED),
            {keep_state, Data}
    end;

handle_requeue(_MsgId, _Timeout, #conn_data{socket = Socket} = Data) ->
    send_error(Socket, ?E_REQ_FAILED),
    {keep_state, Data}.

handle_touch(MsgId, #conn_data{socket = Socket, subscribed = true, in_flight = InFlight} = Data) ->
    case maps:is_key(MsgId, InFlight) of
        true ->
            logger:info("TOUCH msg_id=~s~n", [MsgId]),

            %% TODO: 调用 erwind_channel:touch(MsgId)

            send_response(Socket, <<"OK">>),
            {keep_state, Data};
        false ->
            send_error(Socket, ?E_TOUCH_FAILED),
            {keep_state, Data}
    end;

handle_touch(_MsgId, #conn_data{socket = Socket} = Data) ->
    send_error(Socket, ?E_TOUCH_FAILED),
    {keep_state, Data}.

handle_auth(_Secret, #conn_data{socket = Socket} = Data) ->
    %% TODO: 实现认证逻辑
    send_response(Socket, <<"OK">>),
    {keep_state, Data}.

handle_close(#conn_data{socket = Socket} = Data) ->
    logger:info("CLS received, closing connection~n"),
    send_response(Socket, <<"CLOSE_WAIT">>),
    {next_state, closing, Data}.

%% =============================================================================
%% Protocol parsing
%% =============================================================================

%% 解析命令
%% NSQ 协议格式：
%%   - 简单命令: "CMD\n"
%%   - 带 body 的命令: "CMD\n" + 4字节长度(big endian) + body
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
    case binary:split(Line, <<" ">>, [global]) of
        [<<"IDENTIFY">>] ->
            %% IDENTIFY: 4字节长度 + JSON body
            parse_body(Rest, fun(Body, Remain) -> {{identify, Body}, Remain} end);

        [<<"AUTH">>] ->
            %% AUTH: 4字节长度 + secret body
            parse_body(Rest, fun(Body, Remain) -> {{auth, Body}, Remain} end);

        [<<"SUB">>, Topic, Channel] ->
            {{sub, Topic, Channel}, Rest};

        [<<"PUB">>, Topic] ->
            %% PUB: 4字节长度 + message body
            parse_body(Rest, fun(Body, Remain) -> {{pub, Topic, Body}, Remain} end);

        [<<"MPUB">>, Topic] ->
            %% MPUB: 4字节长度 + messages body
            parse_body(Rest, fun(Body, Remain) -> {{mpub, Topic, Body}, Remain} end);

        [<<"DPUB">>, Topic, DeferBin] ->
            %% DPUB: 4字节长度 + message body
            case parse_integer(DeferBin) of
                {ok, DeferMs} ->
                    parse_body(Rest, fun(Body, Remain) -> {{dpub, Topic, DeferMs, Body}, Remain} end);
                error ->
                    {{error, ?E_INVALID}, Rest}
            end;

        [<<"RDY">>, CountBin] ->
            case parse_integer(CountBin) of
                {ok, Count} -> {{rdy, Count}, Rest};
                error -> {{error, ?E_INVALID}, Rest}
            end;

        [<<"FIN">>, MsgId] ->
            {{fin, MsgId}, Rest};

        [<<"REQ">>, MsgId, TimeoutBin] ->
            case parse_integer(TimeoutBin) of
                {ok, Timeout} -> {{req, MsgId, Timeout}, Rest};
                error -> {{req, MsgId, 0}, Rest}
            end;

        [<<"TOUCH">>, MsgId] ->
            {{touch, MsgId}, Rest};

        [<<"CLS">>] ->
            {cls, Rest};

        [<<"NOP">>] ->
            {nop, Rest};

        _ ->
            {{error, ?E_INVALID}, Rest}
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

%% 解析 IDENTIFY 参数 (简化版 JSON 解析)
parse_identify_params(Bin) ->
    try
        Params = parse_json_object(Bin),
        {ok, Params}
    catch
        _:_ -> {error, invalid_json}
    end.

%% 验证 IDENTIFY 参数
validate_identify(Params, Data) ->
    {ok, Data#conn_data{
        client_id = maps:get(<<"client_id">>, Params, undefined),
        hostname = maps:get(<<"hostname">>, Params, undefined),
        features = maps:get(<<"feature_negotiation">>, Params, #{}),
        heartbeat_interval = maps:get(<<"heartbeat_interval">>, Params, ?DEFAULT_HEARTBEAT_INTERVAL),
        msg_timeout = maps:get(<<"msg_timeout">>, Params, ?DEFAULT_MSG_TIMEOUT)
    }}.

%% 简单的 JSON 对象解析器 (仅处理 IDENTIFY 需要的简单情况)
parse_json_object(<<>>) ->
    #{};
parse_json_object(Bin) ->
    %% 去除首尾空格和大括号
    Trimmed = binary:replace(Bin, [<<" ">>, <<"\n">>, <<"\r">>, <<"\t">>], <<>>, [global]),
    <<"{", Content/binary>> = Trimmed,
    Size = byte_size(Content),
    <<Inner:(Size-1)/binary, "}">> = Content,
    parse_json_pairs(Inner, #{}).

parse_json_pairs(<<>>, Acc) ->
    Acc;
parse_json_pairs(Bin, Acc) ->
    %% 找到键值对
    case binary:split(Bin, <<":">>) of
        [KeyPart, Rest] ->
            Key = parse_json_string(KeyPart),
            {Value, Remaining} = parse_json_value(Rest),
            NewAcc = maps:put(Key, Value, Acc),
            %% 检查是否有更多键值对
            case binary:split(Remaining, <<",">>) of
                [_, More] -> parse_json_pairs(More, NewAcc);
                [_] -> NewAcc
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
                _ -> Bin
            end
    end.

%% =============================================================================
%% Utility functions
%% =============================================================================

parse_integer(Bin) ->
    try
        {ok, binary_to_integer(Bin)}
    catch
        _:_ -> error
    end.

start_heartbeat(#conn_data{heartbeat_interval = Interval, heartbeat_ref = OldRef} = Data) ->
    %% 取消旧的心跳定时器
    case OldRef of
        undefined -> ok;
        _ -> erlang:cancel_timer(OldRef)
    end,
    TimerRef = erlang:send_after(Interval, self(), heartbeat_tick),
    Data#conn_data{heartbeat_ref = TimerRef}.

%% =============================================================================
%% Protocol sending
%% =============================================================================

%% 发送响应帧
send_response(Socket, Body) ->
    send_frame(Socket, ?FRAME_TYPE_RESPONSE, Body).

%% 发送错误帧
send_error(Socket, Body) when is_binary(Body) ->
    send_frame(Socket, ?FRAME_TYPE_ERROR, Body);
send_error(Socket, Body) when is_list(Body) ->
    send_frame(Socket, ?FRAME_TYPE_ERROR, iolist_to_binary(Body)).

%% 发送消息帧
send_message(Socket, #nsq_message{id = Id, timestamp = Ts, attempts = Att, body = Body}) ->
    %% NSQ 消息格式: [id(16)] [timestamp(8)] [attempts(2)] [body(N)]
    MsgBin = <<Id:16/binary, Ts:64/big, Att:16/big, Body/binary>>,
    send_frame(Socket, ?FRAME_TYPE_MESSAGE, MsgBin).

%% 发送协议帧
send_frame(Socket, Type, Body) ->
    Size = byte_size(Body),
    Frame = <<Type:32/big, Size:32/big, Body/binary>>,
    gen_tcp:send(Socket, Frame).

%% 发送心跳
send_heartbeat(Socket) ->
    send_response(Socket, <<"_heartbeat_">>).
