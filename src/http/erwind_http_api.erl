%% erwind_http_api.erl
%% HTTP API 模块 - 提供管理接口和监控接口

-module(erwind_http_api).
-behaviour(cowboy_handler).

%% Cowboy 回调
-export([init/2]).

%% API 路由表
-export([routes/0]).

%% =============================================================================
%% 路由配置
%% =============================================================================

routes() ->
    [
        {"/", ?MODULE, #{handler => index}},
        {"/ping", ?MODULE, #{handler => ping}},
        {"/info", ?MODULE, #{handler => info}},
        {"/stats", ?MODULE, #{handler => stats}},
        {"/topic/create", ?MODULE, #{handler => topic_create}},
        {"/topic/delete", ?MODULE, #{handler => topic_delete}},
        {"/topic/empty", ?MODULE, #{handler => topic_empty}},
        {"/topic/pause", ?MODULE, #{handler => topic_pause}},
        {"/topic/unpause", ?MODULE, #{handler => topic_unpause}},
        {"/topic/list", ?MODULE, #{handler => topic_list}},
        {"/channel/create", ?MODULE, #{handler => channel_create}},
        {"/channel/delete", ?MODULE, #{handler => channel_delete}},
        {"/channel/empty", ?MODULE, #{handler => channel_empty}},
        {"/channel/pause", ?MODULE, #{handler => channel_pause}},
        {"/channel/unpause", ?MODULE, #{handler => channel_unpause}},
        {"/pub", ?MODULE, #{handler => pub}},
        {"/mpub", ?MODULE, #{handler => mpub}},
        {"/dpub", ?MODULE, #{handler => dpub}}
    ].

%% =============================================================================
%% Cowboy 初始化
%% =============================================================================

init(Req, #{handler := Handler} = State) ->
    Method = cowboy_req:method(Req),
    %% 处理 CORS 预检请求
    case Method of
        <<"OPTIONS">> ->
            handle_cors_preflight(Req, State);
        _ ->
            handle_request(Handler, Method, Req, State)
    end.

%% 处理 CORS 预检请求
handle_cors_preflight(Req, State) ->
    case get_cors_config() of
        disabled ->
            Req2 = cowboy_req:reply(204, #{}, <<>>, Req),
            {ok, Req2, State};
        CorsConfig ->
            Headers = build_cors_headers(CorsConfig),
            Req2 = cowboy_req:reply(204, Headers, <<>>, Req),
            {ok, Req2, State}
    end.

%% 获取 CORS 配置
get_cors_config() ->
    case application:get_env(erwind, cors) of
        {ok, Config} -> Config;
        undefined -> #{enabled => true, origin => <<"*">>}
    end.

%% 构建 CORS 头
build_cors_headers(#{enabled := true, origin := Origin}) ->
    #{
        <<"access-control-allow-origin">> => Origin,
        <<"access-control-allow-methods">> => <<"GET, POST, OPTIONS">>,
        <<"access-control-allow-headers">> => <<"Content-Type">>
    };
build_cors_headers(_) -> #{}.

%% =============================================================================
%% 请求处理
%% =============================================================================

%% 首页 - API 信息
handle_request(index, <<"GET">>, Req, State) ->
    ApiInfo = #{
        name => <<"Erwind HTTP API">>,
        version => get_version(),
        description => <<"NSQ-compatible message queue HTTP API">>,
        endpoints => [
            #{method => <<"GET">>, path => <<"/ping">>, description => <<"Health check">>},
            #{method => <<"GET">>, path => <<"/info">>, description => <<"Node information">>},
            #{method => <<"GET">>, path => <<"/stats">>, description => <<"Statistics">>},
            #{method => <<"GET">>, path => <<"/topic/list">>, description => <<"List all topics">>},
            #{method => <<"POST">>, path => <<"/topic/create?topic=">>, description => <<"Create topic">>},
            #{method => <<"POST">>, path => <<"/topic/delete?topic=">>, description => <<"Delete topic">>},
            #{method => <<"POST">>, path => <<"/topic/pause?topic=">>, description => <<"Pause topic">>},
            #{method => <<"POST">>, path => <<"/topic/unpause?topic=">>, description => <<"Unpause topic">>},
            #{method => <<"POST">>, path => <<"/channel/create?topic=&channel=">>, description => <<"Create channel">>},
            #{method => <<"POST">>, path => <<"/channel/delete?topic=&channel=">>, description => <<"Delete channel">>},
            #{method => <<"POST">>, path => <<"/pub?topic=">>, description => <<"Publish message">>},
            #{method => <<"POST">>, path => <<"/mpub?topic=">>, description => <<"Batch publish">>},
            #{method => <<"POST">>, path => <<"/dpub?topic=&defer=">>, description => <<"Delayed publish">>}
        ]
    },
    reply_json(Req, ApiInfo, State);

%% 健康检查
handle_request(ping, <<"GET">>, Req, State) ->
    Headers = maps:merge(cors_headers(), #{<<"content-type">> => <<"text/plain">>}),
    Req2 = cowboy_req:reply(200, Headers, <<"OK">>, Req),
    {ok, Req2, State};

%% 节点信息
handle_request(info, <<"GET">>, Req, State) ->
    Info = #{
        version => get_version(),
        broadcast_address => get_broadcast_address(),
        hostname => get_hostname(),
        http_port => get_http_port(),
        tcp_port => get_tcp_port(),
        start_time => get_start_time()
    },
    reply_json(Req, Info, State);

%% 统计信息
handle_request(stats, <<"GET">>, Req, State) ->
    Stats = collect_stats(),
    reply_json(Req, Stats, State);

%% 创建 Topic
handle_request(topic_create, <<"POST">>, Req, State) ->
    QS = cowboy_req:parse_qs(Req),
    case lists:keyfind(<<"topic">>, 1, QS) of
        {_, TopicName} when is_binary(TopicName) ->
            case erwind_topic_registry:create_topic(TopicName) of
                {ok, _} ->
                    reply_json(Req, #{message => <<"OK">>}, State);
                {error, already_exists} ->
                    reply_error(Req, 409, <<"topic already exists">>, State);
                {error, Reason} ->
                    reply_error(Req, 500, Reason, State)
            end;
        _ ->
            reply_error(Req, 400, <<"missing topic parameter">>, State)
    end;

%% 删除 Topic
handle_request(topic_delete, <<"POST">>, Req, State) ->
    QS = cowboy_req:parse_qs(Req),
    case lists:keyfind(<<"topic">>, 1, QS) of
        {_, TopicName} ->
            case erwind_topic_registry:delete_topic(TopicName) of
                ok ->
                    reply_json(Req, #{message => <<"OK">>}, State);
                {error, not_found} ->
                    reply_error(Req, 404, <<"topic not found">>, State);
                {error, Reason} ->
                    reply_error(Req, 500, Reason, State)
            end;
        false ->
            reply_error(Req, 400, <<"missing topic parameter">>, State)
    end;

%% 清空 Topic
handle_request(topic_empty, <<"POST">>, Req, State) ->
    QS = cowboy_req:parse_qs(Req),
    case lists:keyfind(<<"topic">>, 1, QS) of
        {_, TopicName} ->
            case erwind_topic_registry:lookup_topic(TopicName) of
                {ok, Pid} ->
                    ok = erwind_topic:empty(Pid),
                    reply_json(Req, #{message => <<"OK">>}, State);
                not_found ->
                    reply_error(Req, 404, <<"topic not found">>, State)
            end;
        false ->
            reply_error(Req, 400, <<"missing topic parameter">>, State)
    end;

%% 暂停 Topic
handle_request(topic_pause, <<"POST">>, Req, State) ->
    QS = cowboy_req:parse_qs(Req),
    case lists:keyfind(<<"topic">>, 1, QS) of
        {_, TopicName} ->
            case erwind_topic_registry:lookup_topic(TopicName) of
                {ok, Pid} ->
                    ok = erwind_topic:pause(Pid),
                    reply_json(Req, #{message => <<"OK">>}, State);
                not_found ->
                    reply_error(Req, 404, <<"topic not found">>, State)
            end;
        false ->
            reply_error(Req, 400, <<"missing topic parameter">>, State)
    end;

%% 恢复 Topic
handle_request(topic_unpause, <<"POST">>, Req, State) ->
    QS = cowboy_req:parse_qs(Req),
    case lists:keyfind(<<"topic">>, 1, QS) of
        {_, TopicName} ->
            case erwind_topic_registry:lookup_topic(TopicName) of
                {ok, Pid} ->
                    ok = erwind_topic:unpause(Pid),
                    reply_json(Req, #{message => <<"OK">>}, State);
                not_found ->
                    reply_error(Req, 404, <<"topic not found">>, State)
            end;
        false ->
            reply_error(Req, 400, <<"missing topic parameter">>, State)
    end;

%% 列出 Topics
handle_request(topic_list, <<"GET">>, Req, State) ->
    TopicsWithPids = erwind_topic_registry:list_topics(),
    TopicNames = [Name || {Name, _Pid} <- TopicsWithPids],
    reply_json(Req, #{topics => TopicNames}, State);

%% 创建 Channel
handle_request(channel_create, <<"POST">>, Req, State) ->
    QS = cowboy_req:parse_qs(Req),
    case {lists:keyfind(<<"topic">>, 1, QS), lists:keyfind(<<"channel">>, 1, QS)} of
        {{_, TopicName}, {_, ChannelName}} ->
            case erwind_topic_registry:lookup_topic(TopicName) of
                {ok, TopicPid} ->
                    case erwind_topic:create_channel(TopicPid, ChannelName) of
                        {ok, _} ->
                            reply_json(Req, #{message => <<"OK">>}, State);
                        {error, already_exists} ->
                            reply_error(Req, 409, <<"channel already exists">>, State);
                        {error, Reason} ->
                            reply_error(Req, 500, Reason, State)
                    end;
                not_found ->
                    reply_error(Req, 404, <<"topic not found">>, State)
            end;
        _ ->
            reply_error(Req, 400, <<"missing topic or channel parameter">>, State)
    end;

%% 删除 Channel
handle_request(channel_delete, <<"POST">>, Req, State) ->
    QS = cowboy_req:parse_qs(Req),
    case {lists:keyfind(<<"topic">>, 1, QS), lists:keyfind(<<"channel">>, 1, QS)} of
        {{_, TopicName}, {_, ChannelName}} ->
            case erwind_topic_registry:lookup_topic(TopicName) of
                {ok, TopicPid} ->
                    case erwind_topic:delete_channel(TopicPid, ChannelName) of
                        ok ->
                            reply_json(Req, #{message => <<"OK">>}, State);
                        {error, not_found} ->
                            reply_error(Req, 404, <<"channel not found">>, State);
                        {error, Reason} ->
                            reply_error(Req, 500, Reason, State)
                    end;
                not_found ->
                    reply_error(Req, 404, <<"topic not found">>, State)
            end;
        _ ->
            reply_error(Req, 400, <<"missing topic or channel parameter">>, State)
    end;

%% 清空 Channel
handle_request(channel_empty, <<"POST">>, Req, State) ->
    QS = cowboy_req:parse_qs(Req),
    case {lists:keyfind(<<"topic">>, 1, QS), lists:keyfind(<<"channel">>, 1, QS)} of
        {{_, TopicName}, {_, ChannelName}} ->
            case erwind_topic_registry:lookup_topic(TopicName) of
                {ok, TopicPid} ->
                    case erwind_topic:get_channel(TopicPid, ChannelName) of
                        {ok, ChannelPid} ->
                            ok = erwind_channel:empty(ChannelPid),
                            reply_json(Req, #{message => <<"OK">>}, State);
                        {error, not_found} ->
                            reply_error(Req, 404, <<"channel not found">>, State)
                    end;
                not_found ->
                    reply_error(Req, 404, <<"topic not found">>, State)
            end;
        _ ->
            reply_error(Req, 400, <<"missing topic or channel parameter">>, State)
    end;

%% 暂停 Channel
handle_request(channel_pause, <<"POST">>, Req, State) ->
    QS = cowboy_req:parse_qs(Req),
    case {lists:keyfind(<<"topic">>, 1, QS), lists:keyfind(<<"channel">>, 1, QS)} of
        {{_, TopicName}, {_, ChannelName}} ->
            case erwind_topic_registry:lookup_topic(TopicName) of
                {ok, TopicPid} ->
                    case erwind_topic:get_channel(TopicPid, ChannelName) of
                        {ok, ChannelPid} ->
                            ok = erwind_channel:pause(ChannelPid),
                            reply_json(Req, #{message => <<"OK">>}, State);
                        {error, not_found} ->
                            reply_error(Req, 404, <<"channel not found">>, State)
                    end;
                not_found ->
                    reply_error(Req, 404, <<"topic not found">>, State)
            end;
        _ ->
            reply_error(Req, 400, <<"missing topic or channel parameter">>, State)
    end;

%% 恢复 Channel
handle_request(channel_unpause, <<"POST">>, Req, State) ->
    QS = cowboy_req:parse_qs(Req),
    case {lists:keyfind(<<"topic">>, 1, QS), lists:keyfind(<<"channel">>, 1, QS)} of
        {{_, TopicName}, {_, ChannelName}} ->
            case erwind_topic_registry:lookup_topic(TopicName) of
                {ok, TopicPid} ->
                    case erwind_topic:get_channel(TopicPid, ChannelName) of
                        {ok, ChannelPid} ->
                            ok = erwind_channel:unpause(ChannelPid),
                            reply_json(Req, #{message => <<"OK">>}, State);
                        {error, not_found} ->
                            reply_error(Req, 404, <<"channel not found">>, State)
                    end;
                not_found ->
                    reply_error(Req, 404, <<"topic not found">>, State)
            end;
        _ ->
            reply_error(Req, 400, <<"missing topic or channel parameter">>, State)
    end;

%% 发布消息
handle_request(pub, <<"POST">>, Req, State) ->
    QS = cowboy_req:parse_qs(Req),
    case lists:keyfind(<<"topic">>, 1, QS) of
        {_, TopicName} ->
            {ok, Body, Req2} = cowboy_req:read_body(Req),
            case erwind_topic:publish(TopicName, Body) of
                ok ->
                    reply_json(Req2, #{message => <<"OK">>}, State);
                {error, topic_not_found} ->
                    reply_error(Req2, 404, <<"topic not found">>, State);
                {error, paused} ->
                    reply_error(Req2, 503, <<"topic is paused">>, State);
                {error, Reason} ->
                    reply_error(Req2, 500, Reason, State)
            end;
        false ->
            reply_error(Req, 400, <<"missing topic parameter">>, State)
    end;

%% 批量发布
handle_request(mpub, <<"POST">>, Req, State) ->
    QS = cowboy_req:parse_qs(Req),
    case lists:keyfind(<<"topic">>, 1, QS) of
        {_, TopicName} ->
            {ok, Body, Req2} = cowboy_req:read_body(Req),
            Messages = binary:split(Body, <<"\n">>, [global, trim_all]),
            case erwind_topic:mpub(TopicName, Messages) of
                ok ->
                    reply_json(Req2, #{message => <<"OK">>}, State);
                {error, topic_not_found} ->
                    reply_error(Req2, 404, <<"topic not found">>, State);
                {error, Reason} ->
                    reply_error(Req2, 500, Reason, State)
            end;
        false ->
            reply_error(Req, 400, <<"missing topic parameter">>, State)
    end;

%% 延迟发布
handle_request(dpub, <<"POST">>, Req, State) ->
    QS = cowboy_req:parse_qs(Req),
    case {lists:keyfind(<<"topic">>, 1, QS), lists:keyfind(<<"defer">>, 1, QS)} of
        {{_, TopicName}, {_, DeferMsBin}} ->
            {ok, Body, Req2} = cowboy_req:read_body(Req),
            DeferMs = binary_to_integer(DeferMsBin),
            case erwind_topic:dpub(TopicName, Body, DeferMs) of
                ok ->
                    reply_json(Req2, #{message => <<"OK">>}, State);
                {error, topic_not_found} ->
                    reply_error(Req2, 404, <<"topic not found">>, State);
                {error, Reason} ->
                    reply_error(Req2, 500, Reason, State)
            end;
        _ ->
            reply_error(Req, 400, <<"missing topic or defer parameter">>, State)
    end;

%% 默认处理
handle_request(_Handler, _Method, Req, State) ->
    reply_error(Req, 405, <<"method not allowed">>, State).

%% =============================================================================
%% 统计信息收集
%% =============================================================================

collect_stats() ->
    Topics = collect_topic_stats(),
    #{
        version => get_version(),
        health => health_status(),
        start_time => get_start_time(),
        topics => length(Topics),
        topic_list => Topics
    }.

collect_topic_stats() ->
    lists:map(fun({TopicName, TopicPid}) ->
        case erwind_topic_registry:lookup_topic(TopicName) of
            {ok, _} ->
                TopicStats = erwind_topic:get_stats(TopicPid),
                Channels = erwind_topic:list_channels(TopicPid),
                #{
                    name => TopicName,
                    depth => maps:get(depth, TopicStats, 0),
                    message_count => maps:get(message_count, TopicStats, 0),
                    paused => maps:get(paused, TopicStats, false),
                    channels => [
                        #{
                            name => ChName,
                            depth => erwind_channel:get_depth(ChPid),
                            consumers => erwind_channel:get_consumer_count(ChPid)
                        } || {ChName, ChPid} <- Channels
                    ]
                };
            _ ->
                #{name => TopicName, error => <<"topic not accessible">>}
        end
    end, erwind_topic_registry:list_topics()).

%% =============================================================================
%% 响应工具函数
%% =============================================================================

%% CORS 头
cors_headers() ->
    case get_cors_config() of
        disabled -> #{<<"content-type">> => <<"application/json">>};
        CorsConfig -> maps:merge(#{<<"content-type">> => <<"application/json">>}, build_cors_headers(CorsConfig))
    end.

reply_json(Req, Data, State) ->
    Body = jsx:encode(Data),
    true = is_binary(Body),
    Req2 = cowboy_req:reply(200, cors_headers(), Body, Req),
    {ok, Req2, State}.

reply_error(Req, Code, Message, State) when is_binary(Message) ->
    Body = jsx:encode(#{message => Message}),
    true = is_binary(Body),
    Headers = cors_headers(),
    Req2 = cowboy_req:reply(Code, Headers, Body, Req),
    {ok, Req2, State};
reply_error(Req, Code, Message, State) when is_atom(Message) ->
    reply_error(Req, Code, atom_to_binary(Message, utf8), State);
reply_error(Req, Code, Message, State) ->
    reply_error(Req, Code, list_to_binary(io_lib:format("~p", [Message])), State).

%% =============================================================================
%% 辅助函数
%% =============================================================================

get_version() ->
    case application:get_key(erwind, vsn) of
        {ok, Vsn} when is_list(Vsn) -> list_to_binary(Vsn);
        _ -> <<"0.0.0">>
    end.

get_broadcast_address() ->
    case application:get_env(erwind, broadcast_address) of
        {ok, Addr} -> Addr;
        undefined -> <<"127.0.0.1">>
    end.

get_hostname() ->
    case inet:gethostname() of
        {ok, Hostname} -> list_to_binary(Hostname);
        _ -> <<"localhost">>
    end.

get_http_port() ->
    case application:get_env(erwind, http_port) of
        {ok, Port} -> Port;
        undefined -> 4151
    end.

get_tcp_port() ->
    case application:get_env(erwind, tcp_port) of
        {ok, Port} -> Port;
        undefined -> 4150
    end.

get_start_time() ->
    case erwind_stats:get_start_time() of
        Time when is_integer(Time) ->
            Rfc3339String = calendar:system_time_to_rfc3339(Time, [{unit, millisecond}]),
            true = is_list(Rfc3339String),
            list_to_binary(Rfc3339String);
        _ ->
            <<"unknown">>
    end.

health_status() ->
    case whereis(erwind_sup) of
        undefined -> <<"DOWN">>;
        _ -> <<"OK">>
    end.
