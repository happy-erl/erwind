%% erwind_protocol_tests.erl
%% Tests for NSQ protocol module

-module(erwind_protocol_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("../include/erwind.hrl").

%% =============================================================================
%% Frame Encoding/Decoding Tests
%% =============================================================================

frame_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [
        fun encode_response_frame_test/0,
        fun encode_error_frame_test/0,
        fun encode_message_frame_test/0,
        fun decode_response_frame_test/0,
        fun decode_error_frame_test/0,
        fun decode_incomplete_frame_test/0
     ]}.

setup() ->
    ok.

cleanup(_) ->
    ok.

%% =============================================================================
%% Frame Encoding Tests
%% =============================================================================

encode_response_frame_test() ->
    Body = <<"OK">>,
    Frame = erwind_protocol:encode_response(Body),
    %% Frame format: [type:4][length:4][body:N]
    <<Type:32/big, Length:32/big, BodyData/binary>> = Frame,
    ?assertEqual(?FRAME_TYPE_RESPONSE, Type),
    ?assertEqual(byte_size(Body), Length),
    ?assertEqual(Body, BodyData).

encode_error_frame_test() ->
    Body = ?E_INVALID,
    Frame = erwind_protocol:encode_error(Body),
    <<Type:32/big, Length:32/big, BodyData/binary>> = Frame,
    ?assertEqual(?FRAME_TYPE_ERROR, Type),
    ?assertEqual(byte_size(Body), Length),
    ?assertEqual(Body, BodyData).

encode_message_frame_test() ->
    Msg = #nsq_message{
        id = <<"0123456789abcdef">>,
        timestamp = 1234567890000,
        attempts = 1,
        body = <<"hello world">>
    },
    Frame = erwind_protocol:encode_message(Msg),
    <<Type:32/big, Length:32/big, MsgData/binary>> = Frame,
    ?assertEqual(?FRAME_TYPE_MESSAGE, Type),
    ?assertEqual(byte_size(MsgData), Length),
    %% Verify message format: [timestamp:8][attempts:2][id:16][body:N]
    <<Ts:64/big, Att:16/big, Id:16/binary, Body/binary>> = MsgData,
    ?assertEqual(1234567890000, Ts),
    ?assertEqual(1, Att),
    ?assertEqual(<<"0123456789abcdef">>, Id),
    ?assertEqual(<<"hello world">>, Body).

%% =============================================================================
%% Frame Decoding Tests
%% =============================================================================

decode_response_frame_test() ->
    Body = <<"OK">>,
    Frame = erwind_protocol:encode_response(Body),
    {ok, {Type, DecodedBody}, <<>>} = erwind_protocol:decode_frame(Frame),
    ?assertEqual(response, Type),
    ?assertEqual(Body, DecodedBody).

decode_error_frame_test() ->
    Body = ?E_BAD_TOPIC,
    Frame = erwind_protocol:encode_error(Body),
    {ok, {Type, DecodedBody}, <<>>} = erwind_protocol:decode_frame(Frame),
    ?assertEqual(error, Type),
    ?assertEqual(Body, DecodedBody).

decode_incomplete_frame_test() ->
    %% Frame with missing data
    Incomplete = <<?FRAME_TYPE_RESPONSE:32/big, 100:32/big, "short">>,
    ?assertEqual(incomplete, erwind_protocol:decode_frame(Incomplete)).

%% =============================================================================
%% Command Parsing Tests
%% =============================================================================

command_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [
        fun parse_nop_test/0,
        fun parse_identify_test/0,
        fun parse_sub_test/0,
        fun parse_pub_test/0,
        fun parse_rdy_test/0,
        fun parse_fin_test/0,
        fun parse_req_test/0,
        fun parse_touch_test/0,
        fun parse_cls_test/0,
        fun parse_incomplete_test/0,
        fun parse_invalid_test/0
     ]}.

parse_nop_test() ->
    {ok, nop, <<>>} = erwind_protocol:parse_command(<<"NOP\n">>).

parse_identify_test() ->
    Body = <<"{\"client_id\":\"test\"}">>,
    Size = byte_size(Body),
    Cmd = <<"IDENTIFY\n", Size:32/big, Body/binary>>,
    {ok, {identify, Body}, <<>>} = erwind_protocol:parse_command(Cmd).

parse_sub_test() ->
    {ok, {sub, <<"mytopic">>, <<"mychannel">>}, <<>>} =
        erwind_protocol:parse_command(<<"SUB mytopic mychannel\n">>).

parse_pub_test() ->
    Body = <<"hello world">>,
    Size = byte_size(Body),
    Cmd = <<"PUB mytopic\n", Size:32/big, Body/binary>>,
    {ok, {pub, <<"mytopic">>, Body}, <<>>} = erwind_protocol:parse_command(Cmd).

parse_rdy_test() ->
    {ok, {rdy, 100}, <<>>} = erwind_protocol:parse_command(<<"RDY 100\n">>).

parse_fin_test() ->
    MsgId = <<"0123456789abcdef">>,
    {ok, {fin, MsgId}, <<>>} =
        erwind_protocol:parse_command(<<"FIN ", MsgId/binary, "\n">>).

parse_req_test() ->
    MsgId = <<"0123456789abcdef">>,
    {ok, {req, MsgId, 60000}, <<>>} =
        erwind_protocol:parse_command(<<"REQ ", MsgId/binary, " 60000\n">>).

parse_touch_test() ->
    MsgId = <<"0123456789abcdef">>,
    {ok, {touch, MsgId}, <<>>} =
        erwind_protocol:parse_command(<<"TOUCH ", MsgId/binary, "\n">>).

parse_cls_test() ->
    {ok, cls, <<>>} = erwind_protocol:parse_command(<<"CLS\n">>).

parse_incomplete_test() ->
    %% Incomplete command should return incomplete
    {incomplete, <<"NOP">>} = erwind_protocol:parse_command(<<"NOP">>),
    {incomplete, <<"SUB top">>} = erwind_protocol:parse_command(<<"SUB top">>).

parse_invalid_test() ->
    %% Invalid command
    {error, ?E_INVALID} = erwind_protocol:parse_command(<<"INVALID\n">>).

%% =============================================================================
%% Message ID Generation Tests
%% =============================================================================

msg_id_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [
        fun generate_msg_id_test/0,
        fun msg_id_is_unique_test/0,
        fun msg_id_format_test/0
     ]}.

generate_msg_id_test() ->
    MsgId = erwind_protocol:generate_msg_id(),
    ?assertEqual(32, byte_size(MsgId)).

msg_id_is_unique_test() ->
    Id1 = erwind_protocol:generate_msg_id(),
    Id2 = erwind_protocol:generate_msg_id(),
    ?assertNotEqual(Id1, Id2).

msg_id_format_test() ->
    MsgId = erwind_protocol:generate_msg_id(),
    %% Should be valid hex string
    lists:foreach(fun(C) ->
        ?assert((C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f))
    end, binary_to_list(MsgId)).

%% =============================================================================
%% Validation Tests
%% =============================================================================

validation_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [
        fun validate_valid_topic_test/0,
        fun validate_invalid_topic_test/0,
        fun validate_topic_too_long_test/0,
        fun validate_valid_channel_test/0,
        fun validate_ephemeral_channel_test/0
     ]}.

validate_valid_topic_test() ->
    ?assertEqual(ok, erwind_protocol:validate_topic(<<"my_topic">>)),
    ?assertEqual(ok, erwind_protocol:validate_topic(<<"topic-123">>)),
    ?assertEqual(ok, erwind_protocol:validate_topic(<<"a">>)).

validate_invalid_topic_test() ->
    ?assertMatch({error, _}, erwind_protocol:validate_topic(<<"my topic">>)),
    ?assertMatch({error, _}, erwind_protocol:validate_topic(<<"topic.">>)).

validate_topic_too_long_test() ->
    LongTopic = binary:copy(<<"a">>, 33),
    ?assertMatch({error, _}, erwind_protocol:validate_topic(LongTopic)),
    ?assertMatch({error, _}, erwind_protocol:validate_topic(<<>>)).

validate_valid_channel_test() ->
    ?assertEqual(ok, erwind_protocol:validate_channel(<<"my_channel">>)).

validate_ephemeral_channel_test() ->
    ?assertEqual(ok, erwind_protocol:validate_channel(<<"my_channel#ephemeral">>)).

%% =============================================================================
%% JSON Parsing Tests
%% =============================================================================

json_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [
        fun parse_simple_json_test/0,
        fun parse_json_with_integers_test/0,
        fun parse_json_with_strings_test/0,
        fun parse_empty_json_test/0
     ]}.

parse_simple_json_test() ->
    Json = <<"{\"client_id\":\"test\",\"count\":123}">>,
    {ok, Map} = erwind_protocol:parse_json(Json),
    ?assertEqual(<<"test">>, maps:get(<<"client_id">>, Map)),
    ?assertEqual(123, maps:get(<<"count">>, Map)).

parse_json_with_integers_test() ->
    Json = <<"{\"heartbeat_interval\":30000,\"max_rdy\":2500}">>,
    {ok, Map} = erwind_protocol:parse_json(Json),
    ?assertEqual(30000, maps:get(<<"heartbeat_interval">>, Map)),
    ?assertEqual(2500, maps:get(<<"max_rdy">>, Map)).

parse_json_with_strings_test() ->
    Json = <<"{\"hostname\":\"worker1\",\"user_agent\":\"test/1.0\"}">>,
    {ok, Map} = erwind_protocol:parse_json(Json),
    ?assertEqual(<<"worker1">>, maps:get(<<"hostname">>, Map)),
    ?assertEqual(<<"test/1.0">>, maps:get(<<"user_agent">>, Map)).

parse_empty_json_test() ->
    {ok, Map} = erwind_protocol:parse_json(<<"{}">>),
    ?assertEqual(#{}, Map).
