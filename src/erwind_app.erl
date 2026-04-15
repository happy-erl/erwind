%% erwind_app.erl
%% Erwind 应用程序回调模块

-module(erwind_app).
-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% =============================================================================
%% Application callbacks
%% =============================================================================

%% 启动应用程序
-spec start(StartType :: application:start_type(), StartArgs :: term()) ->
    {ok, pid()} | {ok, pid(), State :: term()} | {error, Reason :: term()}.
start(_StartType, _StartArgs) ->
    logger:info("Starting Erwind application"),
    case erwind_sup:start_link() of
        {ok, Pid} -> {ok, Pid};
        {ok, Pid, State} -> {ok, Pid, State};
        {error, Reason} -> {error, Reason};
        ignore -> {error, ignored}
    end.

%% 停止应用程序
-spec stop(State :: term()) -> ok.
stop(_State) ->
    logger:info("Stopping Erwind application"),
    ok.
