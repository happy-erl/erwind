%% erwind_acceptor_tests.erl
%% Tests for Acceptor module

-module(erwind_acceptor_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("erwind/include/erwind.hrl").

%% =============================================================================
%% Unit tests
%% =============================================================================

acceptor_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [
        fun format_addr_test/0
     ]}.

setup() ->
    ok.

cleanup(_) ->
    ok.

%% =============================================================================
%% Tests
%% =============================================================================

format_addr_test() ->
    %% Test IPv4 address formatting
    ?assertEqual("127.0.0.1", erwind_acceptor:format_addr({127,0,0,1})),
    %% Test IPv6 address formatting
    ?assertEqual("::1", erwind_acceptor:format_addr({0,0,0,0,0,0,0,1})),
    %% Test special addresses
    ?assertEqual("local", erwind_acceptor:format_addr(local)),
    ?assertEqual("unspec", erwind_acceptor:format_addr(unspec)).
