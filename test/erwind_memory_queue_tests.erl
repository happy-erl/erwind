%% erwind_memory_queue_tests.erl
%% 内存队列模块测试

-module(erwind_memory_queue_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("erwind/include/erwind.hrl").

%% =============================================================================
%% Test Fixtures
%% =============================================================================

memory_queue_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun start_link_test/0,
      fun in_out_test/0,
      fun push_front_test/0,
      fun len_test/0,
      fun clear_test/0,
      fun max_size_test/0]}.

setup() ->
    {ok, Pid} = erwind_memory_queue:start_link(),
    [{queue, Pid}].

cleanup(State) ->
    Pid = proplists:get_value(queue, State),
    case Pid of
        undefined -> ok;
        _ when is_pid(Pid) -> gen_server:stop(Pid)
    end.

%% =============================================================================
%% Tests
%% =============================================================================

start_link_test() ->
    {ok, Pid} = erwind_memory_queue:start_link(),
    ?assert(is_pid(Pid)),
    gen_server:stop(Pid).

in_out_test() ->
    {ok, Pid} = erwind_memory_queue:start_link(),

    Msg = #nsq_message{
        id = erwind_protocol:generate_msg_id(),
        timestamp = erlang:system_time(millisecond),
        attempts = 1,
        body = <<"test">>
    },

    ok = erwind_memory_queue:in(Pid, Msg),
    {ok, Retrieved} = erwind_memory_queue:out(Pid),

    ?assertEqual(Msg#nsq_message.id, Retrieved#nsq_message.id),
    ?assertEqual(<<"test">>, Retrieved#nsq_message.body),

    %% Queue should be empty now
    ?assertEqual(empty, erwind_memory_queue:out(Pid)),

    gen_server:stop(Pid).

push_front_test() ->
    {ok, Pid} = erwind_memory_queue:start_link(),

    Msg1 = #nsq_message{id = <<"msg1">>, timestamp = 1, attempts = 1, body = <<"1">>},
    Msg2 = #nsq_message{id = <<"msg2">>, timestamp = 2, attempts = 1, body = <<"2">>},

    ok = erwind_memory_queue:in(Pid, Msg1),
    ok = erwind_memory_queue:push_front(Pid, Msg2),

    %% Msg2 should come out first (push_front)
    {ok, First} = erwind_memory_queue:out(Pid),
    ?assertEqual(<<"msg2">>, First#nsq_message.id),

    gen_server:stop(Pid).

len_test() ->
    {ok, Pid} = erwind_memory_queue:start_link(),

    ?assertEqual(0, erwind_memory_queue:len(Pid)),
    ?assert(erwind_memory_queue:is_empty(Pid)),

    Msg = #nsq_message{id = <<"1">>, timestamp = 1, attempts = 1, body = <<>>},
    ok = erwind_memory_queue:in(Pid, Msg),

    ?assertEqual(1, erwind_memory_queue:len(Pid)),
    ?assertNot(erwind_memory_queue:is_empty(Pid)),

    gen_server:stop(Pid).

clear_test() ->
    {ok, Pid} = erwind_memory_queue:start_link(),

    Msg = #nsq_message{id = <<"1">>, timestamp = 1, attempts = 1, body = <<>>},
    ok = erwind_memory_queue:in(Pid, Msg),

    ok = erwind_memory_queue:clear(Pid),
    ?assertEqual(0, erwind_memory_queue:len(Pid)),

    gen_server:stop(Pid).

max_size_test() ->
    {ok, Pid} = erwind_memory_queue:start_link(2),

    Msg1 = #nsq_message{id = <<"1">>, timestamp = 1, attempts = 1, body = <<>>},
    Msg2 = #nsq_message{id = <<"2">>, timestamp = 2, attempts = 1, body = <<>>},
    Msg3 = #nsq_message{id = <<"3">>, timestamp = 3, attempts = 1, body = <<>>},

    ok = erwind_memory_queue:in(Pid, Msg1),
    ok = erwind_memory_queue:in(Pid, Msg2),
    ?assertEqual({error, full}, erwind_memory_queue:in(Pid, Msg3)),

    gen_server:stop(Pid).
