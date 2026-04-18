%% erwind_consumer_manager_tests.erl
%% 消费者管理模块测试

-module(erwind_consumer_manager_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("erwind/include/erwind.hrl").

%% =============================================================================
%% Tests
%% =============================================================================

start_link_test() ->
    {ok, Pid} = erwind_consumer_manager:start_link(<<"topic">>, <<"channel">>),
    ?assert(is_pid(Pid)),
    erwind_consumer_manager:stop(Pid).

register_unregister_test() ->
    {ok, Pid} = erwind_consumer_manager:start_link(<<"topic">>, <<"channel">>),
    ConsumerPid = spawn(fun() -> timer:sleep(1000) end),

    %% Register
    ok = erwind_consumer_manager:register_consumer(Pid, ConsumerPid),
    Consumers = erwind_consumer_manager:get_consumers(Pid),
    ?assert(lists:member(ConsumerPid, Consumers)),

    %% Double register should fail
    ?assertEqual({error, already_registered},
                 erwind_consumer_manager:register_consumer(Pid, ConsumerPid)),

    %% Unregister
    ok = erwind_consumer_manager:unregister_consumer(Pid, ConsumerPid),
    Consumers2 = erwind_consumer_manager:get_consumers(Pid),
    ?assertNot(lists:member(ConsumerPid, Consumers2)),

    ConsumerPid ! kill,
    erwind_consumer_manager:stop(Pid).

update_rdy_test() ->
    {ok, Pid} = erwind_consumer_manager:start_link(<<"topic">>, <<"channel">>),
    ConsumerPid = spawn(fun() -> timer:sleep(1000) end),

    erwind_consumer_manager:register_consumer(Pid, ConsumerPid),
    ok = erwind_consumer_manager:update_rdy(Pid, ConsumerPid, 100),

    Stats = erwind_consumer_manager:get_stats(Pid),
    ?assertEqual(100, maps:get(total_rdy, Stats)),

    erwind_consumer_manager:unregister_consumer(Pid, ConsumerPid),
    ConsumerPid ! kill,
    erwind_consumer_manager:stop(Pid).

select_consumer_test() ->
    {ok, Pid} = erwind_consumer_manager:start_link(<<"topic">>, <<"channel">>),
    Consumer1 = spawn(fun() -> timer:sleep(2000) end),
    Consumer2 = spawn(fun() -> timer:sleep(2000) end),

    erwind_consumer_manager:register_consumer(Pid, Consumer1),
    erwind_consumer_manager:register_consumer(Pid, Consumer2),
    erwind_consumer_manager:update_rdy(Pid, Consumer1, 10),
    erwind_consumer_manager:update_rdy(Pid, Consumer2, 5),

    %% Select should return a consumer with RDY > 0
    {ok, SelectedPid, _Consumer} = erwind_consumer_manager:select_consumer(Pid),
    ?assert(lists:member(SelectedPid, [Consumer1, Consumer2])),

    erwind_consumer_manager:unregister_consumer(Pid, Consumer1),
    erwind_consumer_manager:unregister_consumer(Pid, Consumer2),
    Consumer1 ! kill,
    Consumer2 ! kill,
    erwind_consumer_manager:stop(Pid).

inflight_test() ->
    {ok, Pid} = erwind_consumer_manager:start_link(<<"topic">>, <<"channel">>),
    ConsumerPid = spawn(fun() -> timer:sleep(1000) end),

    erwind_consumer_manager:register_consumer(Pid, ConsumerPid),
    erwind_consumer_manager:update_rdy(Pid, ConsumerPid, 10),

    ok = erwind_consumer_manager:incr_inflight(Pid, ConsumerPid),
    Stats = erwind_consumer_manager:get_stats(Pid),
    ?assertEqual(1, maps:get(total_inflight, Stats)),

    ok = erwind_consumer_manager:decr_inflight(Pid, ConsumerPid),
    Stats2 = erwind_consumer_manager:get_stats(Pid),
    ?assertEqual(0, maps:get(total_inflight, Stats2)),

    erwind_consumer_manager:unregister_consumer(Pid, ConsumerPid),
    ConsumerPid ! kill,
    erwind_consumer_manager:stop(Pid).

get_stats_test() ->
    {ok, Pid} = erwind_consumer_manager:start_link(<<"test_topic">>, <<"test_channel">>),
    Stats = erwind_consumer_manager:get_stats(Pid),

    ?assertEqual(<<"test_topic">>, maps:get(topic, Stats)),
    ?assertEqual(<<"test_channel">>, maps:get(channel, Stats)),
    ?assert(maps:is_key(consumer_count, Stats)),

    erwind_consumer_manager:stop(Pid).
