%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2011-2020, 2600Hz
%%% @doc This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(pqc_ws_client).

-behaviour(gen_server).

-export([connect/2
        ,send/2
        ,close/1
        ,recv/1, recv/2
        ]).

-export([init/1
        ,handle_call/3
        ,handle_cast/2
        ,handle_info/2
        ,terminate/2
        ,code_change/3
        ]).

-include("kazoo_proper.hrl").
-include_lib("kazoo_stdlib/include/kz_types.hrl").

-type conn() :: {pid(), reference()}.

-record(state, {conn :: conn()
               ,events = queue:new() :: queue:queue()
               ,requests = queue:new() :: queue:queue()
               ,parent :: pid()
               }).
-type state() :: #state{}.

-spec connect(kz_term:text(), inet:port_number()) -> pid().
connect(Host, Port) ->
    connect(Host, Port, #{}).

connect(Host, Port, Options) ->
    {'ok', Pid} = gen_server:start_link(?MODULE, [Host, Port, Options, self()], []),
    Pid.

-spec send(pid(), binary()) -> 'ok'.
send(Pid, Payload) ->
    gen_server:call(Pid, {'send', Payload}).

-spec close(pid()) -> 'ok'.
close(Pid) ->
    gen_server:call(Pid, 'close').

-spec recv(pid()) ->
          binary() |
          {'error', 'timeout'}.
recv(Pid) ->
    recv(Pid, 0).

-spec recv(pid(), timeout()) ->
          {'json', kz_json:object()} |
          {'frame', binary()} |
          {'error', 'timeout'}.
recv(Pid, Timeout) ->
    gen_server:call(Pid, {'recv', Timeout}, Timeout + ?MILLISECONDS_IN_SECOND).

-spec init(list()) -> kz_types:startlink_ret().
init([Host, Port, Options, Parent]) ->
    process_flag('trap_exit', 'true'),

    GunOptions = maps:merge(#{protocols => ['http'], retry => 0}
                           ,Options
                           ),
    lager:info("connecting with ~p", [GunOptions]),
    {'ok', ConnPid} = gun:open(Host, Port, GunOptions),
    lager:info("started WS client(~p) to ~s:~p", [ConnPid, Host, Port]),
    {'ok', 'http'} = gun:await_up(ConnPid),

    _UpgradeRef = gun:ws_upgrade(ConnPid, "/", [], #{compress => 'true'}),

    receive
        {'gun_upgrade', ConnPid, StreamRef, [<<"websocket">>], Headers} ->
            lager:info("stream open: ~p(~p): ~p", [ConnPid, StreamRef, Headers]),
            {'ok', #state{conn={ConnPid, StreamRef}, parent=Parent}};
        {'gun_response', ConnPid, _, _, Status, Headers} ->
            {'error', {'ws_upgrade_failed', {Status, Headers}}};
        {'gun_error', ConnPid, _StreamRef, Reason} ->
            {'error', {'ws_upgrade_failed', Reason}}

    after 2 * ?MILLISECONDS_IN_SECOND ->
            {'error', 'timeout'}
    end.

-spec handle_call(any(), kz_term:pid_ref(), state()) -> kz_types:handle_call_ret_state(state()).
handle_call({'send', Payload}, _From, #state{conn={ConnPid, _}}=State) ->
    {'reply', gun:ws_send(ConnPid, {'text', Payload}), State};
handle_call({'recv', Timeout}
           ,From
           ,#state{events=Events
                  ,requests=Requests
                  }=State
           ) ->
    case queue:out(Events) of
        {'empty', Events} ->
            TRef = erlang:send_after(Timeout, self(), {'request_timeout', {From, Timeout}}),
            lager:info("waiting to recv event for ~p", [From]),
            UpdatedRequests = queue:in({From, Timeout, TRef}, Requests),
            {'noreply', State#state{requests=UpdatedRequests}};
        {{'value', Event}, UpdatedEvents} ->
            {'reply', Event, State#state{events=UpdatedEvents}}
    end;
handle_call('close', _From, #state{}=State) ->
    {'stop', 'normal', 'ok', State}.

-spec handle_cast(any(), state()) -> kz_types:handle_cast_ret_state(state()).
handle_cast(_Req, State) ->
    lager:info("ignoring cast ~p", [_Req]),
    {'noreply', State}.

-spec handle_info(any(), state()) -> kz_types:handle_info_ret_state(state()).
handle_info({'gun_ws', ConnPid, StreamRef, {'text', Binary}}, #state{conn={ConnPid, StreamRef}}=State) ->
    MyBinary = binary:copy(Binary),
    Event = {'json', kz_json:decode(MyBinary)},
    handle_ws_event(Event, State);
handle_info({'gun_ws', ConnPid, StreamRef, Frame}, #state{conn={ConnPid, StreamRef}}=State) ->
    Event = {'frame', Frame},
    handle_ws_event(Event, State);
handle_info({'request_timeout', {From, _Timeout}}, #state{requests=Requests}=State) ->
    lager:info("timed out waiting for event for request from ~p", [From]),
    gen_server:reply(From, {'error', 'timeout'}),
    UpdatedRequests = queue:filter(fun({F, _T, _TRef}) -> F =:= From end, Requests),
    {'noreply', State#state{requests=UpdatedRequests}};
handle_info({'EXIT', Parent, _Reason}, #state{parent=Parent}=State) ->
    lager:info("parent ~p down: ~p", [_Reason]),
    {'stop', 'normal', State};
handle_info(_Msg, State) ->
    lager:info("ignoring msg ~p", [_Msg]),
    {'noreply', State}.

-spec terminate(any(), state()) -> 'ok'.
terminate(_Reason, #state{conn={ConnPid, _}}) ->
    gun:ws_send(ConnPid, 'close').

-spec code_change(any(), state(), any()) -> {'ok', state()}.
code_change(_OldVersion, State, _Extra) ->
    {'ok', State}.

handle_ws_event(Event
               ,#state{events=Events
                      ,requests=Requests
                      }=State
               ) ->
    case queue:out(Requests) of
        {'empty', Requests} ->
            {'noreply', State#state{events=queue:in(Event, Events)}};
        {{'value', {From, _Timeout, TRef}}, UpdatedRequests} ->
            lager:info("recv'd event for ~p", [From]),
            gen_server:reply(From, Event),
            'ok' = erlang:cancel_timer(TRef, [{'async', 'true'}, {'info', 'false'}]),
            {'noreply', State#state{requests=UpdatedRequests}}
    end.
