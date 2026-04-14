%% erwind.hrl
%% Erwind 公共头文件

%% =============================================================================
%% 宏定义
%% =============================================================================

%% 协议常量
-define(FRAME_TYPE_RESPONSE, 0).
-define(FRAME_TYPE_ERROR, 1).
-define(FRAME_TYPE_MESSAGE, 2).

%% 错误码
-define(E_INVALID, <<"E_INVALID">>).
-define(E_BAD_TOPIC, <<"E_BAD_TOPIC">>).
-define(E_BAD_CHANNEL, <<"E_BAD_CHANNEL">>).
-define(E_BAD_BODY, <<"E_BAD_BODY">>).
-define(E_REQ_FAILED, <<"E_REQ_FAILED">>).
-define(E_FIN_FAILED, <<"E_FIN_FAILED">>).
-define(E_PUB_FAILED, <<"E_PUB_FAILED">>).
-define(E_MPUB_FAILED, <<"E_MPUB_FAILED">>).
-define(E_AUTH_FAILED, <<"E_AUTH_FAILED">>).
-define(E_UNAUTHORIZED, <<"E_UNAUTHORIZED">>).
-define(E_SUB_FAILED, <<"E_SUB_FAILED">>).
-define(E_ALREADY_SUBSCRIBED, <<"E_ALREADY_SUBSCRIBED">>).
-define(E_NOT_SUBSCRIBED, <<"E_NOT_SUBSCRIBED">>).
-define(E_TOUCH_FAILED, <<"E_TOUCH_FAILED">>).
-define(E_TOPIC_EXITING, <<"E_TOPIC_EXITING">>).
-define(E_CHANNEL_EXITING, <<"E_CHANNEL_EXITING">>).

%% 默认配置
-define(DEFAULT_TCP_PORT, 4150).
-define(DEFAULT_HTTP_PORT, 4151).
-define(DEFAULT_MSG_TIMEOUT, 60000).
-define(DEFAULT_HEARTBEAT_INTERVAL, 30000).
-define(DEFAULT_MAX_RDY, 2500).
-define(DEFAULT_MAX_MSG_SIZE, 1048576).
-define(DEFAULT_SYNC_EVERY, 2500).
-define(DEFAULT_MAX_BYTES_PER_FILE, 104857600).
-define(DEFAULT_MAX_MEMORY_DEPTH, 10000).

%% 时间常量
-define(TIMEOUT_CHECK_INTERVAL, 5000).
-define(HEARTBEAT_INTERVAL, 15000).
-define(IDENTIFY_TIMEOUT, 10000).

%% =============================================================================
%% 记录定义
%% =============================================================================

%% NSQ 消息记录
-record(nsq_message, {
    id :: binary(),              %% 16 bytes hex string
    timestamp :: integer(),      %% milliseconds since epoch
    attempts = 1 :: integer(),   %% delivery attempts
    body :: binary()             %% message payload
}).

%% NSQ 命令记录
-record(cmd_identify, {params :: map()}).
-record(cmd_auth, {secret :: binary()}).
-record(cmd_sub, {topic :: binary(), channel :: binary()}).
-record(cmd_pub, {topic :: binary(), body :: binary()}).
-record(cmd_mpub, {topic :: binary(), messages :: [binary()]}).
-record(cmd_dpub, {topic :: binary(), defer :: integer(), body :: binary()}).
-record(cmd_rdy, {count :: integer()}).
-record(cmd_fin, {msg_id :: binary()}).
-record(cmd_req, {msg_id :: binary(), timeout :: integer()}).
-record(cmd_touch, {msg_id :: binary()}).
-record(cmd_cls, {}).
-record(cmd_nop, {}).

%% 协议帧记录
-record(protocol_frame, {
    type :: response | error | message,
    body :: binary()
}).

%% 在途消息记录（必须在 consumer 之前定义）
-record(in_flight_msg, {
    msg :: #nsq_message{},
    consumer_pid :: pid(),
    deliver_time :: integer(),
    expire_time :: integer()
}).

%% 消费者记录
-record(consumer, {
    pid :: pid(),
    rdy = 0 :: integer(),
    in_flight = 0 :: integer(),
    msg_timeout = ?DEFAULT_MSG_TIMEOUT :: integer(),
    inflight_msgs = #{} :: #{binary() => #in_flight_msg{}}
}).

%% 磁盘消息记录
-record(disk_msg, {
    length :: integer(),
    timestamp :: integer(),
    body :: binary()
}).

%% 统计计数器记录
-record(stat_counter, {
    key :: term(),
    count = 0 :: non_neg_integer(),
    rate_1m = 0.0 :: float(),
    rate_5m = 0.0 :: float(),
    rate_15m = 0.0 :: float()
}).

%% =============================================================================
%% 类型定义
%% =============================================================================

-type topic_name() :: binary().
-type channel_name() :: binary().
-type msg_id() :: binary().
-type nsq_command() :: #cmd_identify{} | #cmd_sub{} | #cmd_pub{} |
                       #cmd_mpub{} | #cmd_dpub{} | #cmd_rdy{} |
                       #cmd_fin{} | #cmd_req{} | #cmd_touch{} |
                       #cmd_cls{} | #cmd_nop{}.

-export_type([topic_name/0, channel_name/0, msg_id/0, nsq_command/0]).
