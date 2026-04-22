%% erwind_lookupd_tests.erl
%% Lookupd 客户端模块单元测试

-module(erwind_lookupd_tests).

-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% Test Fixtures
%% =============================================================================

lookupd_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [{foreach,
       fun setup_per_test/0,
       fun cleanup_per_test/1,
       [fun start_link_test/0,
        fun register_topic_test/0,
        fun register_channel_test/0,
        fun lookup_topic_local_test/0,
        fun lookup_topic_mocked_test/0,
        fun lookup_nodes_empty_test/0,
        fun lookup_channels_empty_test/0,
        fun set_get_lookupd_addrs_test/0,
        fun unregister_topic_test/0,
        fun unregister_channel_test/0,
        fun multiple_topics_test/0]}]}.

%% 全局测试设置
setup() ->
    %% 确保 inets 已启动
    case inets:start() of
        ok -> ok;
        {error, {already_started, _}} -> ok
    end,

    %% Handle already started case
    case whereis(erwind_lookupd) of
        undefined ->
            {ok, Pid} = erwind_lookupd:start_link(),
            [{lookupd, Pid}];
        Pid when is_pid(Pid) ->
            [{lookupd, Pid}]
    end.

cleanup(_State) ->
    ok.  %% Don't kill shared lookupd process

%% 每个测试的设置
setup_per_test() ->
    %% 清空已注册的 topics 和 channels 状态
    %% 通过设置空的 lookupd 地址来实现
    erwind_lookupd:set_lookupd_addrs([]),
    ok.

cleanup_per_test(_State) ->
    ok.

%% =============================================================================
%% 基础测试
%% =============================================================================

start_link_test() ->
    ?assert(is_pid(whereis(erwind_lookupd))).

%% =============================================================================
%% Topic 注册测试
%% =============================================================================

register_topic_test() ->
    %% Use unique topic name
    TopicName = iolist_to_binary([<<"register_topic_">>, integer_to_binary(erlang:unique_integer([positive]))]),

    %% 设置空的 lookupd 地址（本地测试模式）
    ok = erwind_lookupd:set_lookupd_addrs([]),

    %% 注册 Topic
    ok = erwind_lookupd:register_topic(TopicName),

    %% 由于 lookupd 地址为空，lookup 会返回空列表
    {ok, Results} = erwind_lookupd:lookup_topic(TopicName),
    ?assertEqual([], Results),

    %% 清理
    ok = erwind_lookupd:unregister_topic(TopicName).

unregister_topic_test() ->
    TopicName = iolist_to_binary([<<"unregister_topic_">>, integer_to_binary(erlang:unique_integer([positive]))]),

    %% 设置空的 lookupd 地址
    ok = erwind_lookupd:set_lookupd_addrs([]),

    %% 注册然后注销
    ok = erwind_lookupd:register_topic(TopicName),
    ok = erwind_lookupd:unregister_topic(TopicName),

    %% 验证已注销
    {ok, Results} = erwind_lookupd:lookup_topic(TopicName),
    ?assertEqual([], Results).

%% =============================================================================
%% Channel 注册测试
%% =============================================================================

register_channel_test() ->
    UniqueId = erlang:unique_integer([positive]),
    TopicName = iolist_to_binary([<<"ch_topic_">>, integer_to_binary(UniqueId)]),
    ChannelName = iolist_to_binary([<<"ch_name_">>, integer_to_binary(UniqueId)]),

    %% 设置空的 lookupd 地址
    ok = erwind_lookupd:set_lookupd_addrs([]),

    %% 注册 Channel
    ok = erwind_lookupd:register_channel(TopicName, ChannelName),

    %% 清理
    ok = erwind_lookupd:unregister_channel(TopicName, ChannelName).

unregister_channel_test() ->
    UniqueId = erlang:unique_integer([positive]),
    TopicName = iolist_to_binary([<<"unch_topic_">>, integer_to_binary(UniqueId)]),
    ChannelName = iolist_to_binary([<<"unch_name_">>, integer_to_binary(UniqueId)]),

    %% 设置空的 lookupd 地址
    ok = erwind_lookupd:set_lookupd_addrs([]),

    %% 注册然后注销
    ok = erwind_lookupd:register_channel(TopicName, ChannelName),
    ok = erwind_lookupd:unregister_channel(TopicName, ChannelName).

%% =============================================================================
%% Lookup 查询测试 - 本地模式
%% =============================================================================

lookup_topic_local_test() ->
    %% 设置空的 lookupd 地址，返回空结果
    ok = erwind_lookupd:set_lookupd_addrs([]),

    %% 查询不存在的 topic
    {ok, Results} = erwind_lookupd:lookup_topic(<<"nonexistent_local_topic">>),
    ?assertEqual([], Results).

lookup_nodes_empty_test() ->
    %% 设置空的 lookupd 地址
    ok = erwind_lookupd:set_lookupd_addrs([]),

    {ok, Results} = erwind_lookupd:lookup_nodes(),
    ?assertEqual([], Results).

lookup_channels_empty_test() ->
    %% 设置空的 lookupd 地址
    ok = erwind_lookupd:set_lookupd_addrs([]),

    {ok, Results} = erwind_lookupd:lookup_channels(<<"test_topic">>),
    ?assertEqual([], Results).

%% =============================================================================
%% Lookup 查询测试 - Mock 模式（简化版）
%% =============================================================================

lookup_topic_mocked_test() ->
    %% 启动一个简单的 TCP 服务器作为 mock
    {ok, ListenSocket} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(ListenSocket),

    %% 在单独的进程中运行 mock 服务器，只处理一个请求
    spawn(fun() ->
        {ok, Client} = gen_tcp:accept(ListenSocket, 3000),
        inet:setopts(Client, [{active, once}]),
        receive
            {tcp, Client, _Data} ->
                Body0 = jsx:encode(#{
                    channels => [],
                    producers => [
                        #{
                            broadcast_address => <<"127.0.0.1">>,
                            hostname => <<"test-host">>,
                            tcp_port => 4150,
                            http_port => 4151
                        }
                    ],
                    topic => <<"test_topic">>
                }),
                Body = case is_binary(Body0) of true -> Body0; false -> <<"{}">> end,
                Response = iolist_to_binary([
                    "HTTP/1.1 200 OK\r\n",
                    "Content-Type: application/json\r\n",
                    "Content-Length: ", integer_to_list(byte_size(Body)), "\r\n",
                    "Connection: close\r\n",
                    "\r\n",
                    Body
                ]),
                gen_tcp:send(Client, Response),
                gen_tcp:close(Client)
        after 2000 ->
            gen_tcp:close(Client)
        end,
        gen_tcp:close(ListenSocket)
    end),

    %% 设置 lookupd 地址为 mock 服务器
    MockAddr = "127.0.0.1:" ++ integer_to_list(Port),
    ok = erwind_lookupd:set_lookupd_addrs([MockAddr]),

    %% 查询 topic（使用较短的超时）
    {ok, Results} = erwind_lookupd:lookup_topic(<<"test_topic">>),

    %% 验证结果格式
    ?assert(is_list(Results)),

    %% 清理
    erwind_lookupd:set_lookupd_addrs([]),
    gen_tcp:close(ListenSocket),
    ok.

%% =============================================================================
%% 地址配置测试
%% =============================================================================

set_get_lookupd_addrs_test() ->
    %% 获取初始地址
    InitialAddrs = erwind_lookupd:get_lookupd_addrs(),
    ?assert(is_list(InitialAddrs)),

    %% 设置新地址
    TestAddrs = ["127.0.0.1:4161", "127.0.0.1:4162"],
    ok = erwind_lookupd:set_lookupd_addrs(TestAddrs),

    %% 验证设置成功
    NewAddrs = erwind_lookupd:get_lookupd_addrs(),
    ?assertEqual(TestAddrs, NewAddrs),

    %% 恢复初始地址
    ok = erwind_lookupd:set_lookupd_addrs(InitialAddrs).

%% =============================================================================
%% 多 Topic 测试
%% =============================================================================

multiple_topics_test() ->
    %% 设置空的 lookupd 地址
    ok = erwind_lookupd:set_lookupd_addrs([]),

    %% 创建多个 topics
    Topics = [iolist_to_binary([<<"multi_topic_">>, integer_to_binary(I), <<"_">>,
                                 integer_to_binary(erlang:unique_integer([positive]))])
              || I <- lists:seq(1, 5)],

    %% 注册所有 topics
    lists:foreach(fun(Topic) when is_binary(Topic) ->
        ok = erwind_lookupd:register_topic(Topic)
    end, Topics),

    %% 验证每个 topic 都能查到（虽然 lookupd 为空，但测试不会崩溃）
    lists:foreach(fun(Topic) when is_binary(Topic) ->
        {ok, _} = erwind_lookupd:lookup_topic(Topic)
    end, Topics),

    %% 注销所有 topics
    lists:foreach(fun(Topic) when is_binary(Topic) ->
        ok = erwind_lookupd:unregister_topic(Topic)
    end, Topics).
