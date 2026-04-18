%% erwind_backend_queue_tests.erl
%% Backend Queue 模块测试 - 内存 + 磁盘混合存储

-module(erwind_backend_queue_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("erwind/include/erwind.hrl").

%% =============================================================================
%% Tests
%% =============================================================================

start_stop_test() ->
    {ok, Pid} = erwind_backend_queue:start_link(<<"start_stop">>),
    ?assert(is_pid(Pid)),
    ok = erwind_backend_queue:stop(Pid).

put_get_test() ->
    {ok, Pid} = erwind_backend_queue:start_link(<<"put_get">>),

    Msg = #nsq_message{
        id = erwind_protocol:generate_msg_id(),
        timestamp = erlang:system_time(millisecond),
        attempts = 1,
        body = <<"test message">>
    },

    ok = erwind_backend_queue:put(Pid, Msg),
    {ok, Retrieved} = erwind_backend_queue:get(Pid),

    ?assertEqual(Msg#nsq_message.id, Retrieved#nsq_message.id),
    ?assertEqual(Msg#nsq_message.body, Retrieved#nsq_message.body),

    ok = erwind_backend_queue:stop(Pid).

put_batch_test() ->
    {ok, Pid} = erwind_backend_queue:start_link(<<"batch">>),

    Msgs = [#nsq_message{
        id = erwind_protocol:generate_msg_id(),
        timestamp = erlang:system_time(millisecond),
        attempts = 1,
        body = Body
    } || Body <- [<<"msg1">>, <<"msg2">>, <<"msg3">>]],

    ok = erwind_backend_queue:put_batch(Pid, Msgs),

    %% Retrieve all messages
    {ok, Msg1} = erwind_backend_queue:get(Pid),
    {ok, Msg2} = erwind_backend_queue:get(Pid),
    {ok, Msg3} = erwind_backend_queue:get(Pid),

    ?assertEqual(<<"msg1">>, Msg1#nsq_message.body),
    ?assertEqual(<<"msg2">>, Msg2#nsq_message.body),
    ?assertEqual(<<"msg3">>, Msg3#nsq_message.body),

    ok = erwind_backend_queue:stop(Pid).

empty_queue_test() ->
    {ok, Pid} = erwind_backend_queue:start_link(<<"empty">>),

    ?assertEqual(empty, erwind_backend_queue:get(Pid)),

    ok = erwind_backend_queue:stop(Pid).

put_hybrid_test() ->
    {ok, Pid} = erwind_backend_queue:start_link(<<"hybrid">>),

    %% 写入内存
    Msg1 = #nsq_message{
        id = <<"msg000000000001">>,
        timestamp = 1,
        attempts = 1,
        body = <<"memory1">>
    },
    ok = erwind_backend_queue:put_hybrid(Pid, Msg1),

    %% 读取应成功
    {ok, Retrieved} = erwind_backend_queue:get_hybrid(Pid),
    ?assertEqual(<<"memory1">>, Retrieved#nsq_message.body),

    ok = erwind_backend_queue:stop(Pid).

depth_test() ->
    {ok, Pid} = erwind_backend_queue:start_link(<<"depth">>),

    %% 初始深度
    {MemDepth0, DiskDepth0} = erwind_backend_queue:depth(Pid),
    ?assertEqual(0, MemDepth0),
    ?assertEqual(0, DiskDepth0),

    %% 写入消息
    Msg = #nsq_message{
        id = erwind_protocol:generate_msg_id(),
        timestamp = 1,
        attempts = 1,
        body = <<"test">>
    },
    ok = erwind_backend_queue:put(Pid, Msg),

    {MemDepth1, _} = erwind_backend_queue:depth(Pid),
    ?assertEqual(1, MemDepth1),

    ok = erwind_backend_queue:stop(Pid).

peek_test() ->
    {ok, Pid} = erwind_backend_queue:start_link(<<"peek">>),

    Msg = #nsq_message{
        id = <<"msg000000000001">>,
        timestamp = 1,
        attempts = 1,
        body = <<"peek_test">>
    },
    ok = erwind_backend_queue:put(Pid, Msg),

    %% Peek 不移除消息
    {ok, Peeked} = erwind_backend_queue:peek(Pid),
    ?assertEqual(<<"peek_test">>, Peeked#nsq_message.body),

    %% 队列深度不变
    {MemDepth, _} = erwind_backend_queue:depth(Pid),
    ?assertEqual(1, MemDepth),

    %% Get 才会移除
    {ok, _} = erwind_backend_queue:get(Pid),
    {MemDepth2, _} = erwind_backend_queue:depth(Pid),
    ?assertEqual(0, MemDepth2),

    ok = erwind_backend_queue:stop(Pid).

flush_test() ->
    {ok, Pid} = erwind_backend_queue:start_link(<<"flush">>),

    Msg = #nsq_message{
        id = <<"msg000000000001">>,
        timestamp = 1,
        attempts = 1,
        body = <<"flush_test">>
    },
    ok = erwind_backend_queue:put(Pid, Msg),

    ok = erwind_backend_queue:flush(Pid),

    ok = erwind_backend_queue:stop(Pid).

get_hybrid_from_memory_test() ->
    {ok, Pid} = erwind_backend_queue:start_link(<<"hybrid_mem">>),

    Msg = #nsq_message{
        id = <<"msg000000000001">>,
        timestamp = 1,
        attempts = 1,
        body = <<"from_memory">>
    },

    %% 使用 put_hybrid 写入内存
    ok = erwind_backend_queue:put_hybrid(Pid, Msg),

    %% 使用 get_hybrid 读取
    {ok, Retrieved} = erwind_backend_queue:get_hybrid(Pid),
    ?assertEqual(<<"from_memory">>, Retrieved#nsq_message.body),

    %% 再次读取应为空
    ?assertEqual(empty, erwind_backend_queue:get_hybrid(Pid)),

    ok = erwind_backend_queue:stop(Pid).
