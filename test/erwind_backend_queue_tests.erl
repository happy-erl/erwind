%% erwind_backend_queue_tests.erl
%% Backend Queue 模块单元测试

-module(erwind_backend_queue_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("erwind/include/erwind.hrl").

%% =============================================================================
%% Test Fixtures
%% =============================================================================

queue_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun start_stop_test/0,
      fun put_get_test/0,
      fun put_batch_test/0,
      fun empty_queue_test/0]}.

setup() ->
    {ok, Pid} = erwind_backend_queue:start_link(<<"test_queue">>),
    [{queue, Pid}].

cleanup(State) ->
    case proplists:get_value(queue, State) of
        Pid when is_pid(Pid) -> erwind_backend_queue:delete(Pid);
        _ -> ok
    end.

%% =============================================================================
%% Tests
%% =============================================================================

start_stop_test() ->
    {ok, Pid} = erwind_backend_queue:start_link(<<"start_stop">>),
    ?assert(is_pid(Pid)),
    ok = erwind_backend_queue:delete(Pid).

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

    erwind_backend_queue:delete(Pid).

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

    erwind_backend_queue:delete(Pid).

empty_queue_test() ->
    {ok, Pid} = erwind_backend_queue:start_link(<<"empty">>),

    ?assertEqual(empty, erwind_backend_queue:get(Pid)),

    erwind_backend_queue:delete(Pid).
