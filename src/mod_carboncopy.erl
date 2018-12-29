%%%----------------------------------------------------------------------
%%% File    : mod_carboncopy.erl
%%% Author  : Eric Cestari <ecestari@process-one.net>
%%% Purpose : Message Carbons XEP-0280 0.8
%%% Created : 5 May 2008 by Mickael Remond <mremond@process-one.net>
%%% Usage   : Add the following line in modules section of ejabberd.yml:
%%%              {mod_carboncopy, []}
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2018   ProcessOne
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
-module (mod_carboncopy).

-author ('ecestari@process-one.net').
-protocol({xep, 280, '0.8'}).

-behaviour(gen_mod).

%% API:
-export([start/2, stop/1, reload/3]).

-export([user_send_packet/1, user_receive_packet/1,
	 iq_handler/1, disco_features/5,
	 is_carbon_copy/1, mod_opt_type/1, depends/2,
	 mod_options/1]).
-export([c2s_copy_session/2, c2s_session_opened/1, c2s_session_resumed/1]).
%% For debugging purposes
-export([list/2]).

-include("logger.hrl").
-include("xmpp.hrl").

-type direction() :: sent | received.
-type c2s_state() :: ejabberd_c2s:state().

-spec is_carbon_copy(stanza()) -> boolean().
is_carbon_copy(#message{meta = #{carbon_copy := true}}) ->
    true;
is_carbon_copy(_) ->
    false.

start(Host, _Opts) ->
    ejabberd_hooks:add(disco_local_features, Host, ?MODULE, disco_features, 50),
    %% why priority 89: to define clearly that we must run BEFORE mod_logdb hook (90)
    ejabberd_hooks:add(user_send_packet,Host, ?MODULE, user_send_packet, 89),
    ejabberd_hooks:add(user_receive_packet,Host, ?MODULE, user_receive_packet, 89),
    ejabberd_hooks:add(c2s_copy_session, Host, ?MODULE, c2s_copy_session, 50),
    ejabberd_hooks:add(c2s_session_resumed, Host, ?MODULE, c2s_session_resumed, 50),
    ejabberd_hooks:add(c2s_session_opened, Host, ?MODULE, c2s_session_opened, 50),
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_CARBONS_2, ?MODULE, iq_handler).

stop(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_CARBONS_2),
    ejabberd_hooks:delete(disco_local_features, Host, ?MODULE, disco_features, 50),
    %% why priority 89: to define clearly that we must run BEFORE mod_logdb hook (90)
    ejabberd_hooks:delete(user_send_packet,Host, ?MODULE, user_send_packet, 89),
    ejabberd_hooks:delete(user_receive_packet,Host, ?MODULE, user_receive_packet, 89),
    ejabberd_hooks:delete(c2s_copy_session, Host, ?MODULE, c2s_copy_session, 50),
    ejabberd_hooks:delete(c2s_session_resumed, Host, ?MODULE, c2s_session_resumed, 50),
    ejabberd_hooks:delete(c2s_session_opened, Host, ?MODULE, c2s_session_opened, 50).

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

-spec disco_features({error, stanza_error()} | {result, [binary()]} | empty,
		     jid(), jid(), binary(), binary()) ->
			    {error, stanza_error()} | {result, [binary()]}.
disco_features({error, Err}, _From, _To, _Node, _Lang) ->
    {error, Err};
disco_features(empty, _From, _To, <<"">>, _Lang) ->
    {result, [?NS_CARBONS_2]};
disco_features({result, Feats}, _From, _To, <<"">>, _Lang) ->
    {result, [?NS_CARBONS_2|Feats]};
disco_features(Acc, _From, _To, _Node, _Lang) ->
    Acc.

-spec iq_handler(iq()) -> iq().
iq_handler(#iq{type = set, lang = Lang, from = From,
	       sub_els = [El]} = IQ) when is_record(El, carbons_enable);
					  is_record(El, carbons_disable) ->
    {U, S, R} = jid:tolower(From),
    Result = case El of
		 #carbons_enable{} -> enable(S, U, R, ?NS_CARBONS_2);
		 #carbons_disable{} -> disable(S, U, R)
	     end,
    case Result of
	ok ->
	    xmpp:make_iq_result(IQ);
	{error, _} ->
	    Txt = <<"Database failure">>,
	    xmpp:make_error(IQ, xmpp:err_internal_server_error(Txt, Lang))
    end;
iq_handler(#iq{type = set, lang = Lang} = IQ) ->
    Txt = <<"Only <enable/> or <disable/> tags are allowed">>,
    xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang));
iq_handler(#iq{type = get, lang = Lang} = IQ)->
    Txt = <<"Value 'get' of 'type' attribute is not allowed">>,
    xmpp:make_error(IQ, xmpp:err_not_allowed(Txt, Lang)).

-spec user_send_packet({stanza(), ejabberd_c2s:state()})
      -> {stanza(), ejabberd_c2s:state()} | {stop, {stanza(), ejabberd_c2s:state()}}.
user_send_packet({Packet, C2SState}) ->
    From = xmpp:get_from(Packet),
    To = xmpp:get_to(Packet),
    case check_and_forward(From, To, Packet, sent) of
	{stop, Pkt} -> {stop, {Pkt, C2SState}};
	Pkt -> {Pkt, C2SState}
    end.

-spec user_receive_packet({stanza(), ejabberd_c2s:state()})
      -> {stanza(), ejabberd_c2s:state()} | {stop, {stanza(), ejabberd_c2s:state()}}.
user_receive_packet({Packet, #{jid := JID} = C2SState}) ->
    To = xmpp:get_to(Packet),
    case check_and_forward(JID, To, Packet, received) of
	{stop, Pkt} -> {stop, {Pkt, C2SState}};
	Pkt -> {Pkt, C2SState}
    end.

-spec c2s_copy_session(c2s_state(), c2s_state()) -> c2s_state().
c2s_copy_session(State, #{user := U, server := S, resource := R}) ->
    case ejabberd_sm:get_user_info(U, S, R) of
	offline -> State;
	Info ->
	    case lists:keyfind(carboncopy, 1, Info) of
		{_, CC} -> State#{carboncopy => CC};
		false -> State
	    end
    end.

-spec c2s_session_resumed(c2s_state()) -> c2s_state().
c2s_session_resumed(#{user := U, server := S, resource := R,
		      carboncopy := CC} = State) ->
    ejabberd_sm:set_user_info(U, S, R, carboncopy, CC),
    maps:remove(carboncopy, State);
c2s_session_resumed(State) ->
    State.

-spec c2s_session_opened(c2s_state()) -> c2s_state().
c2s_session_opened(State) ->
    maps:remove(carboncopy, State).

% Modified from original version:
%    - registered to the user_send_packet hook, to be called only once even for multicast
%    - do not support "private" message mode, and do not modify the original packet in any way
%    - we also replicate "read" notifications
-spec check_and_forward(jid(), jid(), stanza(), direction()) ->
			       stanza() | {stop, stanza()}.
check_and_forward(JID, To, Packet, Direction)->
    case is_chat_message(Packet) andalso
	not is_received_muc_pm(To, Packet, Direction) andalso
	not xmpp:has_subtag(Packet, #carbons_private{}) andalso
	not xmpp:has_subtag(Packet, #hint{type = 'no-copy'}) of
	true ->
	    case is_carbon_copy(Packet) of
		false ->
		    send_copies(JID, To, Packet, Direction),
		    Packet;
		true ->
		    %% stop the hook chain, we don't want logging modules to duplicates
		    %% this message
		    {stop, Packet}
	    end;
        _ ->
	    Packet
    end.

%%% Internal
%% Direction = received | sent <received xmlns='urn:xmpp:carbons:1'/>
-spec send_copies(jid(), jid(), message(), direction()) -> ok.
send_copies(JID, To, Packet, Direction)->
    {U, S, R} = jid:tolower(JID),
    PrioRes = ejabberd_sm:get_user_present_resources(U, S),
    {_, AvailRs} = lists:unzip(PrioRes),
    {MaxPrio, _MaxRes} = case catch lists:max(PrioRes) of
	{Prio, Res} -> {Prio, Res};
	_ -> {0, undefined}
    end,

    %% unavailable resources are handled like bare JIDs
    IsBareTo = case {Direction, To} of
	{received, #jid{lresource = <<>>}} -> true;
	{received, #jid{lresource = LRes}} -> not lists:member(LRes, AvailRs);
	_ -> false
    end,
    %% list of JIDs that should receive a carbon copy of this message (excluding the
    %% receiver(s) of the original message
    TargetJIDs = case {IsBareTo, Packet} of
	{true, #message{meta = #{sm_copy := true}}} ->
	    %% The message was sent to our bare JID, and we currently have
	    %% multiple resources with the same highest priority, so the session
	    %% manager routes the message to each of them. We create carbon
	    %% copies only from one of those resources in order to avoid
	    %% duplicates.
	    [];
	{true, _} ->
	    OrigTo = fun(Res) -> lists:member({MaxPrio, Res}, PrioRes) end,
	    [ {jid:make({U, S, CCRes}), CC_Version}
	     || {CCRes, CC_Version} <- list(U, S),
		lists:member(CCRes, AvailRs), not OrigTo(CCRes) ];
	{false, _} ->
	    [ {jid:make({U, S, CCRes}), CC_Version}
	     || {CCRes, CC_Version} <- list(U, S),
		lists:member(CCRes, AvailRs), CCRes /= R ]
	    %TargetJIDs = lists:delete(JID, [ jid:make({U, S, CCRes}) || CCRes <- list(U, S) ]),
    end,

    lists:map(fun({Dest, _Version}) ->
		    {_, _, Resource} = jid:tolower(Dest),
		    ?DEBUG("Sending:  ~p =/= ~p", [R, Resource]),
		    Sender = jid:make({U, S, <<>>}),
		    %{xmlelement, N, A, C} = Packet,
		    New = build_forward_packet(JID, Packet, Sender, Dest, Direction),
		    ejabberd_router:route(xmpp:set_from_to(New, Sender, Dest))
	      end, TargetJIDs),
    ok.

-spec build_forward_packet(jid(), message(), jid(), jid(), direction()) -> message().
build_forward_packet(JID, #message{type = T} = Msg, Sender, Dest, Direction) ->
    Forwarded = #forwarded{sub_els = [complete_packet(JID, Msg, Direction)]},
    Carbon = case Direction of
		 sent -> #carbons_sent{forwarded = Forwarded};
		 received -> #carbons_received{forwarded = Forwarded}
	     end,
    #message{from = Sender, to = Dest, type = T, sub_els = [Carbon],
	     meta = #{carbon_copy => true}}.

-spec enable(binary(), binary(), binary(), binary()) -> ok | {error, any()}.
enable(Host, U, R, CC)->
    ?DEBUG("Enabling carbons for ~s@~s/~s", [U, Host, R]),
    case ejabberd_sm:set_user_info(U, Host, R, carboncopy, CC) of
	ok -> ok;
	{error, Reason} = Err ->
	    ?ERROR_MSG("Failed to disable carbons for ~s@~s/~s: ~p",
		       [U, Host, R, Reason]),
	    Err
    end.

-spec disable(binary(), binary(), binary()) -> ok | {error, any()}.
disable(Host, U, R)->
    ?DEBUG("Disabling carbons for ~s@~s/~s", [U, Host, R]),
    case ejabberd_sm:del_user_info(U, Host, R, carboncopy) of
	ok -> ok;
	{error, notfound} -> ok;
	{error, Reason} = Err ->
	    ?ERROR_MSG("Failed to disable carbons for ~s@~s/~s: ~p",
		       [U, Host, R, Reason]),
	    Err
    end.

-spec complete_packet(jid(), message(), direction()) -> message().
complete_packet(From, #message{from = undefined} = Msg, sent) ->
    %% if this is a packet sent by user on this host, then Packet doesn't
    %% include the 'from' attribute. We must add it.
    Msg#message{from = From};
complete_packet(_From, Msg, _Direction) ->
    Msg.

-spec is_chat_message(stanza()) -> boolean().
is_chat_message(#message{type = chat}) ->
    true;
is_chat_message(#message{type = normal, body = [_|_]}) ->
    true;
is_chat_message(_) ->
    false.

-spec is_received_muc_pm(jid(), message(), direction()) -> boolean().
is_received_muc_pm(#jid{lresource = <<>>}, _Packet, _Direction) ->
    false;
is_received_muc_pm(_To, _Packet, sent) ->
    false;
is_received_muc_pm(_To, Packet, received) ->
    xmpp:has_subtag(Packet, #muc_user{}).

-spec list(binary(), binary()) -> [{Resource :: binary(), Namespace :: binary()}].
list(User, Server) ->
    lists:filtermap(
      fun({Resource, Info}) ->
	      case lists:keyfind(carboncopy, 1, Info) of
		  {_, NS} -> {true, {Resource, NS}};
		  false -> false
	      end
      end, ejabberd_sm:get_user_info(User, Server)).

depends(_Host, _Opts) ->
    [].

mod_opt_type(O) when O == cache_size; O == cache_life_time;
		     O == use_cache; O == cache_missed;
		     O == ram_db_type ->
    fun(deprecated) -> deprecated;
       (_) ->
	    ?WARNING_MSG("Option ~s of ~s has no effect anymore "
			 "and will be ingored", [O, ?MODULE]),
	    deprecated
    end.

mod_options(_) ->
    [{ram_db_type, deprecated},
     {use_cache, deprecated},
     {cache_size, deprecated},
     {cache_missed, deprecated},
     {cache_life_time, deprecated}].
