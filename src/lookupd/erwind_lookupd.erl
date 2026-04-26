%% erwind_lookupd.erl
%% NSQ Lookupd 客户端模块 - 服务注册发现
%% 负责与 nsqlookupd 集群通信，实现服务发现和节点注册

-module(erwind_lookupd).
-behaviour(gen_server).

%% eqWAlizer: 忽略类型转换函数（动态类型过滤无法静态验证）
-eqwalizer_ignore([{filter_string_list, 1}, {safe_list_to_binary, 1}]).

%% API
-export([start_link/0, stop/0]).
-export([register_topic/1, unregister_topic/1,
         register_channel/2, unregister_channel/2]).
-export([lookup/1, lookup_topic/1, lookup_channels/1, lookup_nodes/0]).
-export([set_lookupd_addrs/1, get_lookupd_addrs/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include_lib("erwind/include/erwind.hrl").

%% Lookupd 心跳间隔 15 秒
-define(LOOKUPD_HEARTBEAT_INTERVAL, 15000).
%% HTTP 请求超时 5 秒
-define(HTTP_TIMEOUT, 5000).

-record(state, {
    lookupd_addrs = [] :: [string()],                      %% nsqlookupd 地址列表
    registered_topics = #{} :: #{binary() => integer()},   %% 已注册 Topics (带时间戳)
    registered_channels = #{} :: #{{binary(), binary()} => integer()},  %% 已注册 Channels
    heartbeat_timer :: reference() | undefined,            %% 心跳定时器
    http_port :: integer(),                                %% 本地 HTTP 端口
    tcp_port :: integer()                                  %% 本地 TCP 端口
}).

%% =============================================================================
%% API
%% =============================================================================

%% ## 启动 lookupd 客户端
-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% ## 停止 lookupd 客户端
-spec stop() -> ok.
stop() ->
    gen_server:stop(?MODULE).

%% ##注册 Topic 到所有 nsqlookupd
-spec register_topic(binary()) -> ok.
register_topic(TopicName) when is_binary(TopicName) ->
    gen_server:cast(?MODULE, {register_topic, TopicName}).

%% ##从所有 nsqlookupd 注销 Topic
-spec unregister_topic(binary()) -> ok.
unregister_topic(TopicName) when is_binary(TopicName) ->
    gen_server:cast(?MODULE, {unregister_topic, TopicName}).

%% ##注册 Channel 到所有 nsqlookupd
-spec register_channel(binary(), binary()) -> ok.
register_channel(TopicName, ChannelName) when is_binary(TopicName), is_binary(ChannelName) ->
    gen_server:cast(?MODULE, {register_channel, TopicName, ChannelName}).

%% ##从所有 nsqlookupd 注销 Channel
-spec unregister_channel(binary(), binary()) -> ok.
unregister_channel(TopicName, ChannelName) when is_binary(TopicName), is_binary(ChannelName) ->
    gen_server:cast(?MODULE, {unregister_channel, TopicName, ChannelName}).

%% ##查询 Topic 所在节点（向后兼容别名）
-spec lookup(binary()) -> {ok, [map()]} | {error, term()}.
lookup(TopicName) when is_binary(TopicName) ->
    lookup_topic(TopicName).

%% ##查询 Topic 所在节点
-spec lookup_topic(binary()) -> {ok, [map()]} | {error, term()}.
lookup_topic(TopicName) when is_binary(TopicName) ->
    Result = gen_server:call(?MODULE, {lookup_topic, TopicName}, 10000),
    validate_map_list_result(Result).

%% ##查询 Topic 的所有 Channels
-spec lookup_channels(binary()) -> {ok, [binary()]} | {error, term()}.
lookup_channels(TopicName) when is_binary(TopicName) ->
    Result = gen_server:call(?MODULE, {lookup_channels, TopicName}, 10000),
    validate_binary_list_result(Result).

%% ##查询所有节点
-spec lookup_nodes() -> {ok, [map()]} | {error, term()}.
lookup_nodes() ->
    Result = gen_server:call(?MODULE, lookup_nodes, 10000),
    validate_map_list_result(Result).

%% ###验证结果为 map 列表
-spec validate_map_list_result(term()) -> {ok, [map()]} | {error, term()}.
validate_map_list_result(Result) ->
    case Result of
        {ok, List} when is_list(List) ->
            Filtered = [Item || Item <- List, is_map(Item)],
            {ok, Filtered};
        {error, _} = Err -> Err;
        _ -> {error, unexpected_result}
    end.

%% ###验证结果为 binary 列表
-spec validate_binary_list_result(term()) -> {ok, [binary()]} | {error, term()}.
validate_binary_list_result(Result) ->
    case Result of
        {ok, List} when is_list(List) ->
            Filtered = [Item || Item <- List, is_binary(Item)],
            {ok, Filtered};
        {error, _} = Err -> Err;
        _ -> {error, unexpected_result}
    end.

%% ##设置 nsqlookupd 地址列表
-spec set_lookupd_addrs([string()]) -> ok.
set_lookupd_addrs(Addrs) when is_list(Addrs) ->
    Result = gen_server:call(?MODULE, {set_lookupd_addrs, Addrs}),
    case Result of
        ok -> ok;
        _ -> ok
    end.

%% ##获取当前 nsqlookupd 地址列表
-spec get_lookupd_addrs() -> [string()].
get_lookupd_addrs() ->
    Result = gen_server:call(?MODULE, get_lookupd_addrs),
    filter_string_list(Result).

%% ###过滤字符串列表
-spec filter_string_list(term()) -> [string()].
filter_string_list(List) when is_list(List) ->
    filter_string_list_acc(List, []);
filter_string_list(_) ->
    [].

-spec filter_string_list_acc([term()], [string()]) -> [string()].
filter_string_list_acc([], Acc) ->
    lists:reverse(Acc);
filter_string_list_acc([Item | Rest], Acc) ->
    case is_string(Item) of
        true when is_list(Item) -> filter_string_list_acc(Rest, [Item | Acc]);
        false -> filter_string_list_acc(Rest, Acc)
    end.

%% ###检查是否为字符串
-spec is_string(term()) -> boolean().
is_string(Item) when is_list(Item) ->
    lists:all(fun
        (C) when is_integer(C), C >= 0, C =< 255 -> true;
        (_) -> false
    end, Item);
is_string(_) ->
    false.

%% =============================================================================
%% gen_server callbacks
%% =============================================================================

init([]) ->
    %% 从配置获取 nsqlookupd 地址
    Addrs0 = case application:get_env(erwind, nsqlookupd_http_addresses, []) of
        List when is_list(List) -> List;
        _ -> []
    end,
    %% 过滤只保留字符串类型的地址
    Addrs = filter_string_list(Addrs0),

    %% 获取本地服务端口
    HttpPort = case application:get_env(erwind, http_port, ?DEFAULT_HTTP_PORT) of
        P1 when is_integer(P1), P1 > 0, P1 < 65536 -> P1;
        _ -> ?DEFAULT_HTTP_PORT
    end,
    TcpPort = case application:get_env(erwind, tcp_port, ?DEFAULT_TCP_PORT) of
        P2 when is_integer(P2), P2 > 0, P2 < 65536 -> P2;
        _ -> ?DEFAULT_TCP_PORT
    end,

    %% 启动 httpc 服务（如果尚未启动）
    start_httpc(),

    %% 启动心跳定时器
    Timer = erlang:send_after(?LOOKUPD_HEARTBEAT_INTERVAL, self(), heartbeat),

    logger:info("Lookupd client started with addresses: ~p", [Addrs]),

    {ok, #state{
        lookupd_addrs = Addrs,
        heartbeat_timer = Timer,
        http_port = HttpPort,
        tcp_port = TcpPort
    }}.

handle_call({lookup_topic, TopicName}, _From, State) ->
    Results = lookup_topic_from_all(State#state.lookupd_addrs, TopicName),
    {reply, Results, State};

handle_call({lookup_channels, TopicName}, _From, State) ->
    Results = lookup_channels_from_all(State#state.lookupd_addrs, TopicName),
    {reply, Results, State};

handle_call(lookup_nodes, _From, State) ->
    Results = lookup_nodes_from_all(State#state.lookupd_addrs),
    {reply, Results, State};

handle_call({set_lookupd_addrs, Addrs}, _From, State) ->
    logger:info("Updated lookupd addresses: ~p", [Addrs]),
    {reply, ok, State#state{lookupd_addrs = Addrs}};

handle_call(get_lookupd_addrs, _From, State) ->
    {reply, State#state.lookupd_addrs, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({register_topic, TopicName}, State) ->
    %% 向所有 nsqlookupd 注册
    lists:foreach(fun(Addr) ->
        register_topic_to_addr(Addr, TopicName, State)
    end, State#state.lookupd_addrs),

    %% 记录注册时间戳
    NewTopics = maps:put(TopicName, erlang:system_time(second), State#state.registered_topics),
    {noreply, State#state{registered_topics = NewTopics}};

handle_cast({unregister_topic, TopicName}, State) ->
    %% 从所有 nsqlookupd 注销
    lists:foreach(fun(Addr) ->
        unregister_topic_from_addr(Addr, TopicName)
    end, State#state.lookupd_addrs),

    NewTopics = maps:remove(TopicName, State#state.registered_topics),
    {noreply, State#state{registered_topics = NewTopics}};

handle_cast({register_channel, TopicName, ChannelName}, State) ->
    %% 向所有 nsqlookupd 注册
    lists:foreach(fun(Addr) ->
        register_channel_to_addr(Addr, TopicName, ChannelName, State)
    end, State#state.lookupd_addrs),

    Key = {TopicName, ChannelName},
    NewChannels = maps:put(Key, erlang:system_time(second), State#state.registered_channels),
    {noreply, State#state{registered_channels = NewChannels}};

handle_cast({unregister_channel, TopicName, ChannelName}, State) ->
    %% 从所有 nsqlookupd 注销
    lists:foreach(fun(Addr) ->
        unregister_channel_from_addr(Addr, TopicName, ChannelName)
    end, State#state.lookupd_addrs),

    Key = {TopicName, ChannelName},
    NewChannels = maps:remove(Key, State#state.registered_channels),
    {noreply, State#state{registered_channels = NewChannels}};

handle_cast(_Request, State) ->
    {noreply, State}.

%% 心跳定时器处理
handle_info(heartbeat, State) ->
    %% 重新注册所有 Topics 和 Channels（保持心跳）
    maps:foreach(fun(TopicName, _Ts) ->
        lists:foreach(fun(Addr) ->
            register_topic_to_addr(Addr, TopicName, State)
        end, State#state.lookupd_addrs)
    end, State#state.registered_topics),

    maps:foreach(fun({TopicName, ChannelName}, _Ts) ->
        lists:foreach(fun(Addr) ->
            register_channel_to_addr(Addr, TopicName, ChannelName, State)
        end, State#state.lookupd_addrs)
    end, State#state.registered_channels),

    %% 重启定时器
    Timer = erlang:send_after(?LOOKUPD_HEARTBEAT_INTERVAL, self(), heartbeat),
    {noreply, State#state{heartbeat_timer = Timer}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    %% 取消定时器
    case State#state.heartbeat_timer of
        undefined -> ok;
        Ref -> erlang:cancel_timer(Ref)
    end,

    %% 注销所有 Topics 和 Channels
    maps:foreach(fun(TopicName, _Ts) ->
        lists:foreach(fun(Addr) ->
            unregister_topic_from_addr(Addr, TopicName)
        end, State#state.lookupd_addrs)
    end, State#state.registered_topics),

    maps:foreach(fun({TopicName, ChannelName}, _Ts) ->
        lists:foreach(fun(Addr) ->
            unregister_channel_from_addr(Addr, TopicName, ChannelName)
        end, State#state.lookupd_addrs)
    end, State#state.registered_channels),

    logger:info("Lookupd client stopped"),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =============================================================================
%% HTTP API 调用
%% =============================================================================

%% ###向单个 nsqlookupd 注册 Topic
register_topic_to_addr(Addr, Topic, State) ->
    Url = build_url(Addr, "/topic/create", [{"topic", binary_to_list(Topic)}]),

    ReqBody = jsx:encode(#{
        topic => Topic,
        address => get_broadcast_address(),
        http_port => State#state.http_port,
        tcp_port => State#state.tcp_port
    }),

    Headers = [{"Content-Type", "application/json"}],

    case http_request(post, {Url, Headers, "application/json", ReqBody}) of
        {ok, 200, _Body} ->
            ok;
        {ok, Status, Body} ->
            logger:warning("Register topic failed: addr=~s status=~p body=~s",
                          [Addr, Status, Body]);
        {error, Reason} ->
            logger:warning("Register topic error: addr=~s reason=~p", [Addr, Reason])
    end.

%% ###从单个 nsqlookupd 注销 Topic
unregister_topic_from_addr(Addr, Topic) ->
    Url = build_url(Addr, "/topic/delete", [{"topic", binary_to_list(Topic)}]),

    case http_request(post, {Url, [], "application/json", <<>>}) of
        {ok, 200, _Body} ->
            ok;
        {ok, 404, _Body} ->
            ok;  %% 已经不存在，视为成功
        {ok, Status, Body} ->
            logger:warning("Unregister topic failed: addr=~s status=~p body=~s",
                          [Addr, Status, Body]);
        {error, Reason} ->
            logger:warning("Unregister topic error: addr=~s reason=~p", [Addr, Reason])
    end.

%% ###向单个 nsqlookupd 注册 Channel
register_channel_to_addr(Addr, Topic, Channel, State) ->
    Url = build_url(Addr, "/channel/create", [
        {"topic", binary_to_list(Topic)},
        {"channel", binary_to_list(Channel)}
    ]),

    ReqBody = jsx:encode(#{
        topic => Topic,
        channel => Channel,
        address => get_broadcast_address(),
        http_port => State#state.http_port,
        tcp_port => State#state.tcp_port
    }),

    Headers = [{"Content-Type", "application/json"}],

    case http_request(post, {Url, Headers, "application/json", ReqBody}) of
        {ok, 200, _Body} ->
            ok;
        {ok, Status, Body} ->
            logger:warning("Register channel failed: addr=~s status=~p body=~s",
                          [Addr, Status, Body]);
        {error, Reason} ->
            logger:warning("Register channel error: addr=~s reason=~p", [Addr, Reason])
    end.

%% ###从单个 nsqlookupd 注销 Channel
unregister_channel_from_addr(Addr, Topic, Channel) ->
    Url = build_url(Addr, "/channel/delete", [
        {"topic", binary_to_list(Topic)},
        {"channel", binary_to_list(Channel)}
    ]),

    case http_request(post, {Url, [], "application/json", <<>>}) of
        {ok, 200, _Body} ->
            ok;
        {ok, 404, _Body} ->
            ok;  %% 已经不存在，视为成功
        {ok, Status, Body} ->
            logger:warning("Unregister channel failed: addr=~s status=~p body=~s",
                          [Addr, Status, Body]);
        {error, Reason} ->
            logger:warning("Unregister channel error: addr=~s reason=~p", [Addr, Reason])
    end.

%% ###从所有 nsqlookupd 查询 Topic
lookup_topic_from_all([], _Topic) ->
    {ok, []};
lookup_topic_from_all(Addrs, Topic) ->
    Results = lists:foldl(fun(Addr, Acc0) when is_list(Acc0) ->
        case lookup_topic_from_addr(Addr, Topic) of
            {ok, Nodes} when is_list(Nodes) -> Acc0 ++ Nodes;
            {error, _} -> Acc0
        end
    end, [], Addrs),

    %% 去重（基于 hostname 和 tcp_port）
    ResultsList = case is_list(Results) of true -> Results; false -> [] end,
    UniqueResults = lists:usort(fun(A0, B0) when is_map(A0), is_map(B0) ->
        HostA = maps:get(<<"hostname">>, A0, <<>>),
        HostB = maps:get(<<"hostname">>, B0, <<>>),
        PortA = maps:get(<<"tcp_port">>, A0, 0),
        PortB = maps:get(<<"tcp_port">>, B0, 0),
        if
            HostA < HostB -> true;
            HostA > HostB -> false;
            true -> PortA =< PortB
        end
    end, ResultsList),

    {ok, UniqueResults}.

%% ###从单个 nsqlookupd 查询 Topic
lookup_topic_from_addr(Addr, Topic) ->
    Url = build_url(Addr, "/lookup", [{"topic", binary_to_list(Topic)}]),

    case http_request(get, {Url, []}) of
        {ok, 200, Body} ->
            try
                Opts = [{return_maps, true}],
                Data0 = jsx:decode(Body, Opts),
                Data = case is_map(Data0) of true -> Data0; false -> #{} end,
                Producers = maps:get(<<"producers">>, Data, []),
                {ok, Producers}
            catch
                _:Error ->
                    logger:error("Failed to parse lookup response: ~p", [Error]),
                    {error, invalid_response}
            end;
        {ok, 404, _Body} ->
            {ok, []};  %% Topic 不存在，返回空列表
        {ok, Status, Body} ->
            logger:warning("Lookup topic failed: addr=~s status=~p body=~s",
                          [Addr, Status, Body]),
            {error, {http_error, Status}};
        {error, Reason} ->
            {error, Reason}
    end.

%% ###从所有 nsqlookupd 查询 Channels
lookup_channels_from_all([], _Topic) ->
    {ok, []};
lookup_channels_from_all(Addrs, Topic) ->
    Results = lists:foldl(fun(Addr, Acc0) when is_list(Acc0) ->
        case lookup_channels_from_addr(Addr, Topic) of
            {ok, Channels} when is_list(Channels) -> Acc0 ++ Channels;
            {error, _} -> Acc0
        end
    end, [], Addrs),

    %% 去重
    ResultsList = case is_list(Results) of true -> Results; false -> [] end,
    UniqueResults = lists:usort(ResultsList),
    {ok, UniqueResults}.

%% ###从单个 nsqlookupd 查询 Channels
lookup_channels_from_addr(Addr, Topic) ->
    %% 使用 /lookup 端点获取 Channels 信息
    Url = build_url(Addr, "/lookup", [{"topic", binary_to_list(Topic)}]),

    case http_request(get, {Url, []}) of
        {ok, 200, Body} ->
            try
                Opts = [{return_maps, true}],
                Data0 = jsx:decode(Body, Opts),
                Data = case is_map(Data0) of true -> Data0; false -> #{} end,
                Channels = maps:get(<<"channels">>, Data, []),
                {ok, Channels}
            catch
                _:Error ->
                    logger:error("Failed to parse lookup response: ~p", [Error]),
                    {error, invalid_response}
            end;
        {ok, 404, _Body} ->
            {ok, []};
        {ok, Status, Body} ->
            logger:warning("Lookup channels failed: addr=~s status=~p body=~s",
                          [Addr, Status, Body]),
            {error, {http_error, Status}};
        {error, Reason} ->
            {error, Reason}
    end.

%% ###从所有 nsqlookupd 查询节点
lookup_nodes_from_all([]) ->
    {ok, []};
lookup_nodes_from_all(Addrs) ->
    Results = lists:foldl(fun(Addr, Acc0) when is_list(Acc0) ->
        case lookup_nodes_from_addr(Addr) of
            {ok, Nodes} when is_list(Nodes) -> Acc0 ++ Nodes;
            {error, _} -> Acc0
        end
    end, [], Addrs),

    %% 去重
    ResultsList = case is_list(Results) of true -> Results; false -> [] end,
    UniqueResults = lists:usort(fun(A0, B0) when is_map(A0), is_map(B0) ->
        HostA = maps:get(<<"hostname">>, A0, <<>>),
        HostB = maps:get(<<"hostname">>, B0, <<>>),
        if
            HostA < HostB -> true;
            HostA > HostB -> false;
            true -> true
        end
    end, ResultsList),

    {ok, UniqueResults}.

%% ###从单个 nsqlookupd 查询节点
lookup_nodes_from_addr(Addr) ->
    Url = build_url(Addr, "/nodes", []),

    case http_request(get, {Url, []}) of
        {ok, 200, Body} ->
            try
                Opts = [{return_maps, true}],
                Data0 = jsx:decode(Body, Opts),
                Data = case is_map(Data0) of true -> Data0; false -> #{} end,
                Producers = maps:get(<<"producers">>, Data, []),
                {ok, Producers}
            catch
                _:Error ->
                    logger:error("Failed to parse nodes response: ~p", [Error]),
                    {error, invalid_response}
            end;
        {ok, Status, Body} ->
            logger:warning("Lookup nodes failed: addr=~s status=~p body=~s",
                          [Addr, Status, Body]),
            {error, {http_error, Status}};
        {error, Reason} ->
            {error, Reason}
    end.

%% =============================================================================
%% HTTP 工具函数
%% =============================================================================

%% ###启动 httpc 服务
start_httpc() ->
    case inets:start(httpc, [{profile, ?MODULE}]) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok;
        {error, inets_not_started} ->
            ok = inets:start(),
            start_httpc();
        Error -> Error
    end.

%% ###发送 HTTP 请求
http_request(Method, Request) ->
    try
        HttpOptions = [
            {timeout, ?HTTP_TIMEOUT},
            {connect_timeout, ?HTTP_TIMEOUT}
        ],
        Options = [{body_format, binary}],

        Result = case Method of
            get -> httpc:request(get, Request, HttpOptions, Options, ?MODULE);
            post -> httpc:request(post, Request, HttpOptions, Options, ?MODULE)
        end,

        case Result of
            {ok, {{_, Status, _}, _Headers, Body}} ->
                {ok, Status, Body};
            {error, Reason} ->
                {error, Reason}
        end
    catch
        _:Error ->
            {error, Error}
    end.

%% ###构建 URL
build_url(Addr0, Path, QueryParams) ->
    Addr = case is_list(Addr0) andalso Addr0 =/= [] andalso is_integer(hd(Addr0)) of
        true -> Addr0;
        false -> "127.0.0.1:4161"
    end,
    QueryString = case QueryParams of
        [] -> "";
        _ ->
            Pairs = [K ++ "=" ++ uri_encode(V) || {K, V} <- QueryParams, is_list(K), is_list(V)],
            "?" ++ string:join(Pairs, "&")
    end,
    iolist_to_binary(["http://", Addr, Path, QueryString]).

%% ###URI 编码
uri_encode(String) when is_list(String) ->
    uri_encode_binary(list_to_binary(String));
uri_encode(Binary) when is_binary(Binary) ->
    uri_encode_binary(Binary).

uri_encode_binary(<<>>) ->
    [];
uri_encode_binary(<<C:8, Rest/binary>>) ->
    if
        C >= $a, C =< $z -> [C | uri_encode_binary(Rest)];
        C >= $A, C =< $Z -> [C | uri_encode_binary(Rest)];
        C >= $0, C =< $9 -> [C | uri_encode_binary(Rest)];
        C == $-; C == $_; C == $.; C == $~ -> [C | uri_encode_binary(Rest)];
        true ->
            Hex = io_lib:format("%~2.16.0B", [C]),
            lists:flatten(Hex) ++ uri_encode_binary(Rest)
    end.

%% ###获取广播地址
-spec get_broadcast_address() -> binary().
get_broadcast_address() ->
    case application:get_env(erwind, broadcast_address) of
        {ok, Addr} when is_binary(Addr) -> Addr;
        {ok, Addr} when is_list(Addr) ->
            safe_list_to_binary(Addr);
        undefined ->
            %% 尝试获取主机名
            case inet:gethostname() of
                {ok, Hostname} -> list_to_binary(Hostname);
                _ -> <<"127.0.0.1">>
            end
    end.

%% ###安全地将列表转换为二进制
-spec safe_list_to_binary(term()) -> binary().
safe_list_to_binary(List) when is_list(List) ->
    try
        %% 先验证列表中的元素是否适合转换为二进制
        case validate_iolist(List) of
            {ok, ValidIOList} -> erlang:iolist_to_binary(ValidIOList);
            error -> <<"127.0.0.1">>
        end
    catch
        _:_ -> <<"127.0.0.1">>
    end;
safe_list_to_binary(Bin) when is_binary(Bin) ->
    Bin;
safe_list_to_binary(_) ->
    <<"127.0.0.1">>.

%% ###验证并转换为有效的 iolist
-spec validate_iolist(term()) -> {ok, iolist()} | error.
validate_iolist(List) when is_list(List) ->
    try
        {ok, validate_iolist_acc(List, [])}
    catch
        throw:invalid -> error
    end;
validate_iolist(Bin) when is_binary(Bin) ->
    {ok, Bin};
validate_iolist(_) ->
    error.

-spec validate_iolist_acc([term()], iolist()) -> iolist().
validate_iolist_acc([], Acc) ->
    lists:reverse(Acc);
validate_iolist_acc([Item | Rest], Acc) when is_binary(Item) ->
    validate_iolist_acc(Rest, [Item | Acc]);
validate_iolist_acc([Item | Rest], Acc) when is_integer(Item), Item >= 0, Item =< 255 ->
    validate_iolist_acc(Rest, [Item | Acc]);
validate_iolist_acc([Item | Rest], Acc) when is_list(Item) ->
    {ok, Nested} = validate_iolist(Item),
    validate_iolist_acc(Rest, [Nested | Acc]);
validate_iolist_acc(_, _) ->
    throw(invalid).
