%%%----------------------------------------------------------------------
%%% File    : ejabberd_websocket.erl
%%% Author  : Eric Cestari <ecestari@process-one.net>
%%% Purpose : XMPP Websocket support
%%% Created : 09-10-2010 by Eric Cestari <ecestari@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2015   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%----------------------------------------------------------------------
-module(ejabberd_http_ws).

-author('ecestari@process-one.net').

-behaviour(gen_fsm).

% External exports
-export([start/1, start_link/1, init/1, handle_event/3,
	 handle_sync_event/4, code_change/4, handle_info/3,
	 terminate/3, send_xml/2, setopts/2, sockname/1, peername/1,
	 controlling_process/2, become_controller/2, close/1,
	 socket_handoff/6]).

-include("ejabberd.hrl").
-include("logger.hrl").

-include("jlib.hrl").

-include("ejabberd_http.hrl").

-define(PING_INTERVAL, 60).
-define(WEBSOCKET_TIMEOUT, 300).

-record(state,
        {socket                       :: ws_socket(),
         ping_interval = ?PING_INTERVAL :: non_neg_integer(),
         ping_timer = make_ref()      :: reference(),
         pong_expected                :: boolean(),
         timeout = ?WEBSOCKET_TIMEOUT :: non_neg_integer(),
         timer = make_ref()           :: reference(),
         input = []                   :: list(),
         waiting_input = false        :: false | pid(),
         last_receiver                :: pid(),
         ws                           :: {#ws{}, pid()},
         rfc_compilant = undefined    :: boolean() | undefined}).

%-define(DBGFSM, true).

-ifdef(DBGFSM).

-define(FSMOPTS, [{debug, [trace]}]).

-else.

-define(FSMOPTS, []).

-endif.

-type ws_socket() :: {http_ws, pid(), {inet:ip_address(), inet:port_number()}}.
-export_type([ws_socket/0]).

start(WS) ->
    supervisor:start_child(ejabberd_wsloop_sup, [WS]).

start_link(WS) ->
    gen_fsm:start_link(?MODULE, [WS], ?FSMOPTS).

send_xml({http_ws, FsmRef, _IP}, Packet) ->
    gen_fsm:sync_send_all_state_event(FsmRef,
				      {send_xml, Packet}).

setopts({http_ws, FsmRef, _IP}, Opts) ->
    case lists:member({active, once}, Opts) of
      true ->
	  gen_fsm:send_all_state_event(FsmRef,
				       {activate, self()});
      _ -> ok
    end.

sockname(_Socket) -> {ok, {{0, 0, 0, 0}, 0}}.

peername({http_ws, _FsmRef, IP}) -> {ok, IP}.

controlling_process(_Socket, _Pid) -> ok.

become_controller(FsmRef, C2SPid) ->
    gen_fsm:send_all_state_event(FsmRef,
				 {become_controller, C2SPid}).

close({http_ws, FsmRef, _IP}) ->
    catch gen_fsm:sync_send_all_state_event(FsmRef, close).

socket_handoff(LocalPath, Request, Socket, SockMod, Buf, Opts) ->
    ejabberd_websocket:socket_handoff(LocalPath, Request, Socket, SockMod,
                                      Buf, Opts, ?MODULE, fun get_human_html_xmlel/0).

%%% Internal

init([{#ws{ip = IP}, _} = WS]) ->
    Opts = [{xml_socket, true} | ejabberd_c2s_config:get_c2s_limits()],
    PingInterval = ejabberd_config:get_option(
                     {websocket_ping_interval, ?MYNAME},
                     fun(I) when is_integer(I), I>=0 -> I end,
                     ?PING_INTERVAL) * 1000,
    WSTimeout = ejabberd_config:get_option(
                  {websocket_timeout, ?MYNAME},
                  fun(I) when is_integer(I), I>0 -> I end,
                  ?WEBSOCKET_TIMEOUT) * 1000,
    Socket = {http_ws, self(), IP},
    ?DEBUG("Client connected through websocket ~p",
	   [Socket]),
    ejabberd_socket:start(ejabberd_c2s, ?MODULE, Socket,
			  Opts),
    Timer = erlang:start_timer(WSTimeout, self(), []),
    {ok, loop,
     #state{socket = Socket, timeout = WSTimeout,
            timer = Timer, ws = WS,
            ping_interval = PingInterval}}.

handle_event({activate, From}, StateName, StateData) ->
    case StateData#state.input of
      [] ->
            {next_state, StateName,
             StateData#state{waiting_input = From}};
      Input ->
            Receiver = From,
            Receiver ! {tcp, StateData#state.socket, Input},
            {next_state, StateName,
             StateData#state{input = [], waiting_input = false,
                             last_receiver = Receiver}}
    end.

handle_sync_event({send_xml, Packet}, _From, StateName,
		  #state{ws = {_, WsPid}, rfc_compilant = R} = StateData) ->
    Packet2 = case {case R of undefined -> true; V -> V end, Packet} of
                  {true, {xmlstreamstart, _, Attrs}} ->
                      Attrs2 = [{<<"xmlns">>, <<"urn:ietf:params:xml:ns:xmpp-framing">>} |
                                lists:keydelete(<<"xmlns">>, 1, lists:keydelete(<<"xmlns:stream">>, 1, Attrs))],
                      {xmlstreamelement, #xmlel{name = <<"open">>, attrs = Attrs2}};
                  {true, {xmlstreamend, _}} ->
                      {xmlstreamelement, #xmlel{name = <<"close">>,
                                                attrs = [{<<"xmlns">>, <<"urn:ietf:params:xml:ns:xmpp-framing">>}]}};
                  {true, {xmlstreamraw, <<"\r\n\r\n">>}} -> % cdata ping
                      skip;
                  {true, {xmlstreamelement, #xmlel{name=Name2} = El2}} ->
                      El3 = case Name2 of
                                <<"stream:", _/binary>> ->
                                    xml:replace_tag_attr(<<"xmlns:stream">>, ?NS_STREAM, El2);
                                _ ->
                                    case xml:get_tag_attr_s(<<"xmlns">>, El2) of
                                        <<"">> ->
                                            xml:replace_tag_attr(<<"xmlns">>, <<"jabber:client">>, El2);
                                        _ ->
                                            El2
                                    end
                            end,
                      {xmlstreamelement , El3};
                  _ ->
                      Packet
              end,
    case Packet2 of
        {xmlstreamstart, Name, Attrs3} ->
            B = xml:element_to_binary(#xmlel{name = Name, attrs = Attrs3}),
            WsPid ! {send, <<(binary:part(B, 0, byte_size(B)-2))/binary, ">">>};
        {xmlstreamend, Name} ->
            WsPid ! {send, <<"</", Name/binary, ">">>};
        {xmlstreamelement, El} ->
            WsPid ! {send, xml:element_to_binary(El)};
        {xmlstreamraw, Bin} ->
            WsPid ! {send, Bin};
        {xmlstreamcdata, Bin2} ->
            WsPid ! {send, Bin2};
        skip ->
            ok
    end,
    {reply, ok, StateName, StateData};
handle_sync_event(close, _From, _StateName, StateData) ->
    {stop, normal, StateData}.

handle_info(closed, _StateName, StateData) ->
    {stop, normal, StateData};
handle_info({received, Packet}, StateName, StateDataI) ->
    {StateData, Parsed} = parse(StateDataI, Packet),
    SD = case StateData#state.waiting_input of
             false ->
                 Input = StateData#state.input ++ Parsed,
                 StateData#state{input = Input};
             Receiver ->
                 Receiver ! {tcp, StateData#state.socket, Parsed},
                 setup_timers(StateData#state{waiting_input = false,
                                              last_receiver = Receiver})
         end,
    {next_state, StateName, SD};
handle_info(PingPong, StateName, StateData) when PingPong == ping orelse
                                                 PingPong == pong ->
    StateData2 = setup_timers(StateData),
    {next_state, StateName,
     StateData2#state{pong_expected = false}};
handle_info({timeout, Timer, _}, _StateName,
	    #state{timer = Timer} = StateData) ->
    {stop, normal, StateData};
handle_info({timeout, Timer, _}, StateName,
	    #state{ping_timer = Timer, ws = {_, WsPid}} = StateData) ->
    case StateData#state.pong_expected of
        false ->
            cancel_timer(StateData#state.ping_timer),
            PingTimer = erlang:start_timer(StateData#state.ping_interval,
                                           self(), []),
            WsPid ! {ping, <<>>},
            {next_state, StateName,
             StateData#state{ping_timer = PingTimer, pong_expected = true}};
        true ->
            {stop, normal, StateData}
    end;
handle_info(_, StateName, StateData) ->
    {next_state, StateName, StateData}.

code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.

terminate(_Reason, _StateName, StateData) ->
    case StateData#state.waiting_input of
      false -> ok;
      Receiver ->
	  ?DEBUG("C2S Pid : ~p", [Receiver]),
	  Receiver ! {tcp_closed, StateData#state.socket}
    end,
    ok.

setup_timers(StateData) ->
    cancel_timer(StateData#state.timer),
    Timer = erlang:start_timer(StateData#state.timeout,
                               self(), []),
    cancel_timer(StateData#state.ping_timer),
    PingTimer = case {StateData#state.ping_interval, StateData#state.rfc_compilant} of
                    {0, _} -> StateData#state.ping_timer;
                    {_, false} -> StateData#state.ping_timer;
                    {V, _} -> erlang:start_timer(V, self(), [])
                end,
     StateData#state{timer = Timer, ping_timer = PingTimer,
                     pong_expected = false}.

cancel_timer(Timer) ->
    erlang:cancel_timer(Timer),
    receive {timeout, Timer, _} -> ok after 0 -> ok end.

get_human_html_xmlel() ->
    Heading = <<"ejabberd ", (jlib:atom_to_binary(?MODULE))/binary>>,
    #xmlel{name = <<"html">>,
           attrs =
               [{<<"xmlns">>, <<"http://www.w3.org/1999/xhtml">>}],
           children =
               [#xmlel{name = <<"head">>, attrs = [],
                       children =
                           [#xmlel{name = <<"title">>, attrs = [],
                                   children = [{xmlcdata, Heading}]}]},
                #xmlel{name = <<"body">>, attrs = [],
                       children =
                           [#xmlel{name = <<"h1">>, attrs = [],
                                   children = [{xmlcdata, Heading}]},
                            #xmlel{name = <<"p">>, attrs = [],
                                   children =
                                       [{xmlcdata, <<"An implementation of ">>},
                                        #xmlel{name = <<"a">>,
                                               attrs =
                                                   [{<<"href">>,
                                                     <<"http://tools.ietf.org/html/rfc6455">>}],
                                               children =
                                                   [{xmlcdata,
                                                     <<"WebSocket protocol">>}]}]},
                            #xmlel{name = <<"p">>, attrs = [],
                                   children =
                                       [{xmlcdata,
                                         <<"This web page is only informative. To "
                                           "use WebSocket connection you need a Jabber/XMPP "
                                           "client that supports it.">>}]}]}]}.


parse(#state{rfc_compilant = C} = State, Data) ->
    case C of
        undefined ->
            P = xml_stream:new(self()),
            P2 = xml_stream:parse(P, Data),
            xml_stream:close(P2),
            case parsed_items([]) of
                error ->
                    {State#state{rfc_compilant = true}, <<"parse error">>};
                [] ->
                    {State#state{rfc_compilant = true}, <<"parse error">>};
                [{xmlstreamstart, <<"open">>, _} | _] ->
                    parse(State#state{rfc_compilant = true}, Data);
                _ ->
                    parse(State#state{rfc_compilant = false}, Data)
            end;
        true ->
            El = xml_stream:parse_element(Data),
            case El of
                #xmlel{name = <<"open">>, attrs = Attrs} ->
                    Attrs2 = [{<<"xmlns:stream">>, ?NS_STREAM}, {<<"xmlns">>, <<"jabber:client">>} |
                              lists:keydelete(<<"xmlns">>, 1, lists:keydelete(<<"xmlns:stream">>, 1, Attrs))],
                    {State, [{xmlstreamstart, <<"stream:stream">>, Attrs2}]};
                #xmlel{name = <<"close">>} ->
                    {State, [{xmlstreamend, <<"stream:stream">>}]};
                {error, _} ->
                    {State, <<"parse error">>};
                _ ->
                    {State, [El]}
            end;
        false ->
            {State, Data}
    end.

parsed_items(List) ->
    receive
        {'$gen_event', El}
          when element(1, El) == xmlel;
               element(1, El) == xmlstreamstart;
               element(1, El) == xmlstreamelement;
               element(1, El) == xmlstreamend ->
            parsed_items([El | List]);
        {'$gen_event', {xmlstreamerror, _}} ->
            error
    after 0 ->
            lists:reverse(List)
    end.
