%% erwind_connection_tests.erl
%% Tests for Connection state machine module

-module(erwind_connection_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("erwind/include/erwind.hrl").

%% =============================================================================
%% Protocol parsing tests
%% =============================================================================

protocol_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [
        fun parse_command_nop_test/0,
        fun parse_command_identify_test/0,
        fun parse_command_sub_test/0,
        fun parse_command_pub_test/0,
        fun parse_command_rdy_test/0,
        fun parse_command_fin_test/0,
        fun parse_command_req_test/0,
        fun parse_command_touch_test/0,
        fun parse_command_cls_test/0,
        fun parse_incomplete_test/0
     ]}.

setup() ->
    ok.

cleanup(_) ->
    ok.

%% =============================================================================
%% Tests - Command Parsing
%% =============================================================================

parse_command_nop_test() ->
    %% NOP command
    {nop, <<>>} = erwind_connection:parse_command(<<"NOP\n">>).

parse_command_identify_test() ->
    %% IDENTIFY command with body
    Body = <<"{\"client_id\":\"test\"}">>,
    Size = byte_size(Body),
    Cmd = <<"IDENTIFY\n", Size:32/big, Body/binary>>,
    {{identify, Body}, <<>>} = erwind_connection:parse_command(Cmd).

parse_command_sub_test() ->
    %% SUB command
    {{sub, <<"mytopic">>, <<"mychannel">>}, <<>>} =
        erwind_connection:parse_command(<<"SUB mytopic mychannel\n">>).

parse_command_pub_test() ->
    %% PUB command with body
    Body = <<"hello world">>,
    Size = byte_size(Body),
    Cmd = <<"PUB mytopic\n", Size:32/big, Body/binary>>,
    {{pub, <<"mytopic">>, Body}, <<>>} = erwind_connection:parse_command(Cmd).

parse_command_rdy_test() ->
    %% RDY command
    {{rdy, 100}, <<>>} = erwind_connection:parse_command(<<"RDY 100\n">>).

parse_command_fin_test() ->
    %% FIN command
    MsgId = <<"0123456789abcdef">>,
    {{fin, MsgId}, <<>>} = erwind_connection:parse_command(<<"FIN ", MsgId/binary, "\n">>).

parse_command_req_test() ->
    %% REQ command
    MsgId = <<"0123456789abcdef">>,
    {{req, MsgId, 60000}, <<>>} =
        erwind_connection:parse_command(<<"REQ ", MsgId/binary, " 60000\n">>).

parse_command_touch_test() ->
    %% TOUCH command
    MsgId = <<"0123456789abcdef">>,
    {{touch, MsgId}, <<>>} =
        erwind_connection:parse_command(<<"TOUCH ", MsgId/binary, "\n">>).

parse_command_cls_test() ->
    %% CLS command
    {cls, <<>>} = erwind_connection:parse_command(<<"CLS\n">>).

parse_incomplete_test() ->
    %% Incomplete command should return incomplete
    {incomplete, <<"NOP">>} = erwind_connection:parse_command(<<"NOP">>),
    {incomplete, <<"SUB top">>} = erwind_connection:parse_command(<<"SUB top">>).
