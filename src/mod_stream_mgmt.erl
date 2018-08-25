%%%-------------------------------------------------------------------
%%% Author  : Holger Weiss <holger@zedat.fu-berlin.de>
%%% Created : 25 Dec 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
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
%%%-------------------------------------------------------------------
-module(mod_stream_mgmt).
-behaviour(gen_mod).
-author('holger@zedat.fu-berlin.de').
-protocol({xep, 198, '1.5.2'}).

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_opt_type/1, mod_options/1]).
%% hooks
-export([c2s_stream_init/2, c2s_stream_started/2, c2s_stream_features/2,
	 c2s_authenticated_packet/2, c2s_unauthenticated_packet/2,
	 c2s_unbinded_packet/2, c2s_closed/2, c2s_terminated/2,
	 c2s_handle_send/3, c2s_handle_info/2, c2s_handle_call/3,
	 c2s_handle_recv/3]).
%% adjust pending session timeout / access queue
-export([get_resume_timeout/1, set_resume_timeout/2, queue_find/2]).

-include("xmpp.hrl").
-include("logger.hrl").
-include("p1_queue.hrl").

-define(is_sm_packet(Pkt),
	is_record(Pkt, sm_enable) or
	is_record(Pkt, sm_resume) or
	is_record(Pkt, sm_a) or
	is_record(Pkt, sm_r)).

-type state() :: ejabberd_c2s:state().

%%%===================================================================
%%% API
%%%===================================================================
start(Host, _Opts) ->
    ejabberd_hooks:add(c2s_init, ?MODULE, c2s_stream_init, 50),
    ejabberd_hooks:add(c2s_stream_started, Host, ?MODULE,
		       c2s_stream_started, 50),
    ejabberd_hooks:add(c2s_post_auth_features, Host, ?MODULE,
		       c2s_stream_features, 50),
    ejabberd_hooks:add(c2s_unauthenticated_packet, Host, ?MODULE,
		       c2s_unauthenticated_packet, 50),
    ejabberd_hooks:add(c2s_unbinded_packet, Host, ?MODULE,
		       c2s_unbinded_packet, 50),
    ejabberd_hooks:add(c2s_authenticated_packet, Host, ?MODULE,
		       c2s_authenticated_packet, 50),
    ejabberd_hooks:add(c2s_handle_send, Host, ?MODULE, c2s_handle_send, 50),
    ejabberd_hooks:add(c2s_handle_recv, Host, ?MODULE, c2s_handle_recv, 50),
    ejabberd_hooks:add(c2s_handle_info, Host, ?MODULE, c2s_handle_info, 50),
    ejabberd_hooks:add(c2s_handle_call, Host, ?MODULE, c2s_handle_call, 50),
    ejabberd_hooks:add(c2s_closed, Host, ?MODULE, c2s_closed, 50),
    ejabberd_hooks:add(c2s_terminated, Host, ?MODULE, c2s_terminated, 50).

stop(Host) ->
    case gen_mod:is_loaded_elsewhere(Host, ?MODULE) of
	true ->
	    ok;
	false ->
	    ejabberd_hooks:delete(c2s_init, ?MODULE, c2s_stream_init, 50)
    end,
    ejabberd_hooks:delete(c2s_stream_started, Host, ?MODULE,
			  c2s_stream_started, 50),
    ejabberd_hooks:delete(c2s_post_auth_features, Host, ?MODULE,
			  c2s_stream_features, 50),
    ejabberd_hooks:delete(c2s_unauthenticated_packet, Host, ?MODULE,
			  c2s_unauthenticated_packet, 50),
    ejabberd_hooks:delete(c2s_unbinded_packet, Host, ?MODULE,
			  c2s_unbinded_packet, 50),
    ejabberd_hooks:delete(c2s_authenticated_packet, Host, ?MODULE,
			  c2s_authenticated_packet, 50),
    ejabberd_hooks:delete(c2s_handle_send, Host, ?MODULE, c2s_handle_send, 50),
    ejabberd_hooks:delete(c2s_handle_recv, Host, ?MODULE, c2s_handle_recv, 50),
    ejabberd_hooks:delete(c2s_handle_info, Host, ?MODULE, c2s_handle_info, 50),
    ejabberd_hooks:delete(c2s_handle_call, Host, ?MODULE, c2s_handle_call, 50),
    ejabberd_hooks:delete(c2s_closed, Host, ?MODULE, c2s_closed, 50),
    ejabberd_hooks:delete(c2s_terminated, Host, ?MODULE, c2s_terminated, 50).

reload(_Host, _NewOpts, _OldOpts) ->
    ?WARNING_MSG("module ~s is reloaded, but new configuration will take "
		 "effect for newly created client connections only", [?MODULE]).

depends(_Host, _Opts) ->
    [].

c2s_stream_init({ok, State}, Opts) ->
    MgmtOpts = lists:filter(
		 fun({stream_management, _}) -> true;
		    ({max_ack_queue, _}) -> true;
		    ({resume_timeout, _}) -> true;
		    ({max_resume_timeout, _}) -> true;
		    ({ack_timeout, _}) -> true;
		    ({resend_on_timeout, _}) -> true;
		    ({queue_type, _}) -> true;
		    (_) -> false
		 end, Opts),
    {ok, State#{mgmt_options => MgmtOpts}};
c2s_stream_init(Acc, _Opts) ->
    Acc.

c2s_stream_started(#{lserver := LServer} = State, _StreamStart) ->
    State1 = maps:remove(mgmt_options, State),
    ResumeTimeout = get_configured_resume_timeout(LServer),
    MaxResumeTimeout = get_max_resume_timeout(LServer, ResumeTimeout),
    State1#{mgmt_state => inactive,
	    mgmt_queue_type => get_queue_type(LServer),
	    mgmt_max_queue => get_max_ack_queue(LServer),
	    mgmt_timeout => ResumeTimeout,
	    mgmt_max_timeout => MaxResumeTimeout,
	    mgmt_ack_timeout => get_ack_timeout(LServer),
	    mgmt_resend => get_resend_on_timeout(LServer),
	    mgmt_stanzas_in => 0,
	    mgmt_stanzas_out => 0,
	    mgmt_stanzas_req => 0};
c2s_stream_started(State, _StreamStart) ->
    State.

c2s_stream_features(Acc, Host) ->
    case gen_mod:is_loaded(Host, ?MODULE) of
	true ->
	    [#feature_sm{xmlns = ?NS_STREAM_MGMT_2},
	     #feature_sm{xmlns = ?NS_STREAM_MGMT_3}|Acc];
	false ->
	    Acc
    end.

c2s_unauthenticated_packet(#{lang := Lang} = State, Pkt) when ?is_sm_packet(Pkt) ->
    %% XEP-0198 says: "For client-to-server connections, the client MUST NOT
    %% attempt to enable stream management until after it has completed Resource
    %% Binding unless it is resuming a previous session".  However, it also
    %% says: "Stream management errors SHOULD be considered recoverable", so we
    %% won't bail out.
    Err = #sm_failed{reason = 'not-authorized',
		     text = xmpp:mk_text(<<"Unauthorized">>, Lang),
		     xmlns = ?NS_STREAM_MGMT_3},
    {stop, send(State, Err)};
c2s_unauthenticated_packet(State, _Pkt) ->
    State.

c2s_unbinded_packet(State, #sm_resume{} = Pkt) ->
    case handle_resume(State, Pkt) of
	{ok, ResumedState} ->
	    {stop, ResumedState};
	{error, State1} ->
	    {stop, State1}
    end;
c2s_unbinded_packet(State, Pkt) when ?is_sm_packet(Pkt) ->
    c2s_unauthenticated_packet(State, Pkt);
c2s_unbinded_packet(State, _Pkt) ->
    State.

c2s_authenticated_packet(#{mgmt_state := MgmtState} = State, Pkt)
  when ?is_sm_packet(Pkt) ->
    if MgmtState == pending; MgmtState == active ->
	    {stop, perform_stream_mgmt(Pkt, State)};
       true ->
	    {stop, negotiate_stream_mgmt(Pkt, State)}
    end;
c2s_authenticated_packet(State, Pkt) ->
    update_num_stanzas_in(State, Pkt).

c2s_handle_recv(#{mgmt_state := MgmtState,
		  lang := Lang} = State, El, {error, Why}) ->
    Xmlns = xmpp:get_ns(El),
    IsStanza = xmpp:is_stanza(El),
    if Xmlns == ?NS_STREAM_MGMT_2; Xmlns == ?NS_STREAM_MGMT_3 ->
	    Txt = xmpp:io_format_error(Why),
	    Err = #sm_failed{reason = 'bad-request',
			     text = xmpp:mk_text(Txt, Lang),
			     xmlns = Xmlns},
	    send(State, Err);
       IsStanza andalso (MgmtState == pending orelse MgmtState == active) ->
	    State1 = update_num_stanzas_in(State, El),
	    case xmpp:get_type(El) of
		<<"result">> -> State1;
		<<"error">> -> State1;
		_ ->
		    State1#{mgmt_force_enqueue => true}
	    end;
       true ->
	    State
    end;
c2s_handle_recv(State, _, _) ->
    State.

c2s_handle_send(#{mgmt_state := MgmtState, mod := Mod,
		  lang := Lang} = State, Pkt, SendResult)
  when MgmtState == pending; MgmtState == active ->
    IsStanza = xmpp:is_stanza(Pkt),
    case Pkt of
	_ when IsStanza ->
	    case need_to_enqueue(State, Pkt) of
		{true, State1} ->
		    case mgmt_queue_add(State1, Pkt) of
			#{mgmt_max_queue := exceeded} = State2 ->
			    State3 = State2#{mgmt_resend => false},
			    Err = xmpp:serr_policy_violation(
				    <<"Too many unacked stanzas">>, Lang),
			    send(State3, Err);
			State2 when SendResult == ok ->
			    send_rack(State2);
			State2 ->
			    State2
		    end;
		{false, State1} ->
		    State1
	    end;
	#stream_error{} ->
	    case MgmtState of
		active ->
		    State;
		pending ->
		    Mod:stop(State#{stop_reason => {stream, {out, Pkt}}})
	    end;
	_ ->
	    State
    end;
c2s_handle_send(State, _Pkt, _Result) ->
    State.

c2s_handle_call(#{sid := {Time, _}, mod := Mod, mgmt_queue := Queue} = State,
		{resume_session, Time}, From) ->
    State1 = State#{mgmt_queue => p1_queue:file_to_ram(Queue)},
    Mod:reply(From, {resume, State1}),
    {stop, State#{mgmt_state => resumed}};
c2s_handle_call(#{mod := Mod} = State, {resume_session, _}, From) ->
    Mod:reply(From, {error, <<"Previous session not found">>}),
    {stop, State};
c2s_handle_call(State, _Call, _From) ->
    State.

c2s_handle_info(#{mgmt_ack_timer := TRef, jid := JID, mod := Mod} = State,
		{timeout, TRef, ack_timeout}) ->
    ?DEBUG("Timed out waiting for stream management acknowledgement of ~s",
	   [jid:encode(JID)]),
    State1 = Mod:close(State),
    {stop, transition_to_pending(State1)};
c2s_handle_info(#{mgmt_state := pending, lang := Lang,
		  mgmt_pending_timer := TRef, jid := JID, mod := Mod} = State,
		{timeout, TRef, pending_timeout}) ->
    ?DEBUG("Timed out waiting for resumption of stream for ~s",
	   [jid:encode(JID)]),
    Txt = <<"Timed out waiting for stream resumption">>,
    Err = xmpp:serr_connection_timeout(Txt, Lang),
    Mod:stop(State#{mgmt_state => timeout,
		    stop_reason => {stream, {out, Err}}});
c2s_handle_info(#{jid := JID} = State, {_Ref, {resume, OldState}}) ->
    %% This happens if the resume_session/1 request timed out; the new session
    %% now receives the late response.
    ?DEBUG("Received old session state for ~s after failed resumption",
	   [jid:encode(JID)]),
    route_unacked_stanzas(OldState#{mgmt_resend => false}),
    State;
c2s_handle_info(State, _) ->
    State.

c2s_closed(State, {stream, _}) ->
    State;
c2s_closed(#{mgmt_state := active} = State, _Reason) ->
    {stop, transition_to_pending(State)};
c2s_closed(State, _Reason) ->
    State.

c2s_terminated(#{mgmt_state := resumed, jid := JID} = State, _Reason) ->
    ?DEBUG("Closing former stream of resumed session for ~s",
	   [jid:encode(JID)]),
    bounce_message_queue(),
    {stop, State};
c2s_terminated(#{mgmt_state := MgmtState, mgmt_stanzas_in := In, sid := SID,
		 user := U, server := S, resource := R} = State, Reason) ->
    Result = case MgmtState of
		 timeout ->
		     Info = [{num_stanzas_in, In}],
		     %% TODO: Usually, ejabberd_c2s:process_terminated/2 is
		     %% called later in the hook chain.  We swap the order so
		     %% that the offline info won't be purged after we stored
		     %% it.  This should be fixed in a proper way.
		     State1 = ejabberd_c2s:process_terminated(State, Reason),
		     ejabberd_sm:set_offline_info(SID, U, S, R, Info),
		     {stop, State1};
		 _ ->
		     State
	     end,
    route_unacked_stanzas(State),
    Result;
c2s_terminated(State, _Reason) ->
    State.

%%%===================================================================
%%% Adjust pending session timeout / access queue
%%%===================================================================
-spec get_resume_timeout(state()) -> non_neg_integer().
get_resume_timeout(#{mgmt_timeout := Timeout}) ->
    Timeout.

-spec set_resume_timeout(state(), non_neg_integer()) -> state().
set_resume_timeout(#{mgmt_timeout := Timeout} = State, Timeout) ->
    State;
set_resume_timeout(State, Timeout) ->
    State1 = restart_pending_timer(State, Timeout),
    State1#{mgmt_timeout => Timeout}.

-spec queue_find(fun((stanza()) -> boolean()), p1_queue:queue())
      -> stanza() | none.
queue_find(Pred, Queue) ->
    case p1_queue:out(Queue) of
	{{value, {_, _, Pkt}}, Queue1} ->
	    case Pred(Pkt) of
		true ->
		    Pkt;
		false ->
		    queue_find(Pred, Queue1)
	    end;
	{empty, _Queue1} ->
	    none
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================
-spec negotiate_stream_mgmt(xmpp_element(), state()) -> state().
negotiate_stream_mgmt(Pkt, State) ->
    Xmlns = xmpp:get_ns(Pkt),
    case Pkt of
	#sm_enable{} ->
	    handle_enable(State#{mgmt_xmlns => Xmlns}, Pkt);
	_ when is_record(Pkt, sm_a);
	       is_record(Pkt, sm_r);
	       is_record(Pkt, sm_resume) ->
	    Err = #sm_failed{reason = 'unexpected-request', xmlns = Xmlns},
	    send(State, Err);
	_ ->
	    Err = #sm_failed{reason = 'bad-request', xmlns = Xmlns},
	    send(State, Err)
    end.

-spec perform_stream_mgmt(xmpp_element(), state()) -> state().
perform_stream_mgmt(Pkt, #{mgmt_xmlns := Xmlns, lang := Lang} = State) ->
    case xmpp:get_ns(Pkt) of
	Xmlns ->
	    case Pkt of
		#sm_r{} ->
		    handle_r(State);
		#sm_a{} ->
		    handle_a(State, Pkt);
		_ when is_record(Pkt, sm_enable);
		       is_record(Pkt, sm_resume) ->
		    send(State, #sm_failed{reason = 'unexpected-request',
					   xmlns = Xmlns});
		_ ->
		    send(State, #sm_failed{reason = 'bad-request',
					   xmlns = Xmlns})
	    end;
	_ ->
	    Txt = <<"Unsupported version">>,
	    send(State, #sm_failed{reason = 'unexpected-request',
				   text = xmpp:mk_text(Txt, Lang),
				   xmlns = Xmlns})
    end.

-spec handle_enable(state(), sm_enable()) -> state().
handle_enable(#{mgmt_timeout := DefaultTimeout,
		mgmt_queue_type := QueueType,
		mgmt_max_timeout := MaxTimeout,
		mgmt_xmlns := Xmlns, jid := JID} = State,
	      #sm_enable{resume = Resume, max = Max}) ->
    Timeout = if Resume == false ->
		      0;
		 Max /= undefined, Max > 0, Max =< MaxTimeout ->
		      Max;
		 true ->
		      DefaultTimeout
	      end,
    Res = if Timeout > 0 ->
		  ?DEBUG("Stream management with resumption enabled for ~s",
			 [jid:encode(JID)]),
		  #sm_enabled{xmlns = Xmlns,
			      id = make_resume_id(State),
			      resume = true,
			      max = Timeout};
	     true ->
		  ?DEBUG("Stream management without resumption enabled for ~s",
			 [jid:encode(JID)]),
		  #sm_enabled{xmlns = Xmlns}
	  end,
    State1 = State#{mgmt_state => active,
		    mgmt_queue => p1_queue:new(QueueType),
		    mgmt_timeout => Timeout},
    send(State1, Res).

-spec handle_r(state()) -> state().
handle_r(#{mgmt_xmlns := Xmlns, mgmt_stanzas_in := H} = State) ->
    Res = #sm_a{xmlns = Xmlns, h = H},
    send(State, Res).

-spec handle_a(state(), sm_a()) -> state().
handle_a(State, #sm_a{h = H}) ->
    State1 = check_h_attribute(State, H),
    resend_rack(State1).

-spec handle_resume(state(), sm_resume()) -> {ok, state()} | {error, state()}.
handle_resume(#{user := User, lserver := LServer,
		lang := Lang, socket := Socket} = State,
	      #sm_resume{h = H, previd = PrevID, xmlns = Xmlns}) ->
    R = case inherit_session_state(State, PrevID) of
	    {ok, InheritedState} ->
		{ok, InheritedState, H};
	    {error, Err, InH} ->
		{error, #sm_failed{reason = 'item-not-found',
				   text = xmpp:mk_text(Err, Lang),
				   h = InH, xmlns = Xmlns}, Err};
	    {error, Err} ->
		{error, #sm_failed{reason = 'item-not-found',
				   text = xmpp:mk_text(Err, Lang),
				   xmlns = Xmlns}, Err}
	end,
    case R of
	{ok, #{jid := JID} = ResumedState, NumHandled} ->
	    State1 = check_h_attribute(ResumedState, NumHandled),
	    #{mgmt_xmlns := AttrXmlns, mgmt_stanzas_in := AttrH} = State1,
	    AttrId = make_resume_id(State1),
	    State2 = send(State1, #sm_resumed{xmlns = AttrXmlns,
					      h = AttrH,
					      previd = AttrId}),
	    State3 = resend_unacked_stanzas(State2),
	    State4 = send(State3, #sm_r{xmlns = AttrXmlns}),
	    State5 = ejabberd_hooks:run_fold(c2s_session_resumed, LServer, State4, []),
	    ?INFO_MSG("(~s) Resumed session for ~s",
		      [xmpp_socket:pp(Socket), jid:encode(JID)]),
	    {ok, State5};
	{error, El, Msg} ->
	    ?INFO_MSG("Cannot resume session for ~s@~s: ~s",
		      [User, LServer, Msg]),
	    {error, send(State, El)}
    end.

-spec transition_to_pending(state()) -> state().
transition_to_pending(#{mgmt_state := active, mod := Mod,
			mgmt_timeout := 0} = State) ->
    Mod:stop(State);
transition_to_pending(#{mgmt_state := active, jid := JID,
			lserver := LServer, mgmt_timeout := Timeout} = State) ->
    State1 = cancel_ack_timer(State),
    ?INFO_MSG("Waiting for resumption of stream for ~s", [jid:encode(JID)]),
    TRef = erlang:start_timer(timer:seconds(Timeout), self(), pending_timeout),
    State2 = State1#{mgmt_state => pending, mgmt_pending_timer => TRef},
    ejabberd_hooks:run_fold(c2s_session_pending, LServer, State2, []);
transition_to_pending(State) ->
    State.

-spec check_h_attribute(state(), non_neg_integer()) -> state().
check_h_attribute(#{mgmt_stanzas_out := NumStanzasOut, jid := JID,
		    lang := Lang} = State, H)
  when H > NumStanzasOut ->
    ?WARNING_MSG("~s acknowledged ~B stanzas, but only ~B were sent",
		 [jid:encode(JID), H, NumStanzasOut]),
    State1 = State#{mgmt_resend => false},
    Err = xmpp:serr_undefined_condition(
	    <<"Client acknowledged more stanzas than sent by server">>, Lang),
    send(State1, Err);
check_h_attribute(#{mgmt_stanzas_out := NumStanzasOut, jid := JID} = State, H) ->
    ?DEBUG("~s acknowledged ~B of ~B stanzas",
	   [jid:encode(JID), H, NumStanzasOut]),
    mgmt_queue_drop(State, H).

-spec update_num_stanzas_in(state(), xmpp_element()) -> state().
update_num_stanzas_in(#{mgmt_state := MgmtState,
			mgmt_stanzas_in := NumStanzasIn} = State, El)
  when MgmtState == active; MgmtState == pending ->
    NewNum = case {xmpp:is_stanza(El), NumStanzasIn} of
		 {true, 4294967295} ->
		     0;
		 {true, Num} ->
		     Num + 1;
		 {false, Num} ->
		     Num
	     end,
    State#{mgmt_stanzas_in => NewNum};
update_num_stanzas_in(State, _El) ->
    State.

-spec send_rack(state()) -> state().
send_rack(#{mgmt_ack_timer := _} = State) ->
    State;
send_rack(#{mgmt_xmlns := Xmlns,
	    mgmt_stanzas_out := NumStanzasOut,
	    mgmt_ack_timeout := AckTimeout} = State) ->
    TRef = erlang:start_timer(AckTimeout, self(), ack_timeout),
    State1 = State#{mgmt_ack_timer => TRef, mgmt_stanzas_req => NumStanzasOut},
    send(State1, #sm_r{xmlns = Xmlns}).

-spec resend_rack(state()) -> state().
resend_rack(#{mgmt_ack_timer := _,
	      mgmt_queue := Queue,
	      mgmt_stanzas_out := NumStanzasOut,
	      mgmt_stanzas_req := NumStanzasReq} = State) ->
    State1 = cancel_ack_timer(State),
    case NumStanzasReq < NumStanzasOut andalso not p1_queue:is_empty(Queue) of
	true -> send_rack(State1);
	false -> State1
    end;
resend_rack(State) ->
    State.

-spec mgmt_queue_add(state(), xmlel() | xmpp_element()) -> state().
mgmt_queue_add(#{mgmt_stanzas_out := NumStanzasOut,
		 mgmt_queue := Queue} = State, Pkt) ->
    NewNum = case NumStanzasOut of
		 4294967295 -> 0;
		 Num -> Num + 1
	     end,
    Queue1 = p1_queue:in({NewNum, p1_time_compat:timestamp(), Pkt}, Queue),
    State1 = State#{mgmt_queue => Queue1, mgmt_stanzas_out => NewNum},
    check_queue_length(State1).

-spec mgmt_queue_drop(state(), non_neg_integer()) -> state().
mgmt_queue_drop(#{mgmt_queue := Queue} = State, NumHandled) ->
    NewQueue = p1_queue:dropwhile(
		 fun({N, _T, _E}) -> N =< NumHandled end, Queue),
    State#{mgmt_queue => NewQueue}.

-spec check_queue_length(state()) -> state().
check_queue_length(#{mgmt_max_queue := Limit} = State)
  when Limit == infinity; Limit == exceeded ->
    State;
check_queue_length(#{mgmt_queue := Queue, mgmt_max_queue := Limit} = State) ->
    case p1_queue:len(Queue) > Limit of
	true ->
	    State#{mgmt_max_queue => exceeded};
	false ->
	    State
    end.

-spec resend_unacked_stanzas(state()) -> state().
resend_unacked_stanzas(#{mgmt_state := MgmtState,
			 mgmt_queue := Queue,
			 jid := JID} = State)
  when (MgmtState == active orelse
	MgmtState == pending orelse
	MgmtState == timeout) andalso ?qlen(Queue) > 0 ->
    ?DEBUG("Resending ~B unacknowledged stanza(s) to ~s",
	   [p1_queue:len(Queue), jid:encode(JID)]),
    p1_queue:foldl(
      fun({_, Time, Pkt}, AccState) ->
	      Pkt1 = add_resent_delay_info(AccState, Pkt, Time),
	      Pkt2 = if ?is_stanza(Pkt1) ->
			     xmpp:put_meta(Pkt1, mgmt_is_resent, true);
			true ->
			     Pkt1
		     end,
	      send(AccState, Pkt2)
      end, State, Queue);
resend_unacked_stanzas(State) ->
    State.

-spec route_unacked_stanzas(state()) -> ok.
route_unacked_stanzas(#{mgmt_state := MgmtState,
			mgmt_resend := MgmtResend,
			lang := Lang, user := User,
			jid := JID, lserver := LServer,
			mgmt_queue := Queue,
			resource := Resource} = State)
  when (MgmtState == active orelse
	MgmtState == pending orelse
	MgmtState == timeout) andalso ?qlen(Queue) > 0 ->
    ResendOnTimeout = case MgmtResend of
			  Resend when is_boolean(Resend) ->
			      Resend;
			  if_offline ->
			      case ejabberd_sm:get_user_resources(User, LServer) of
				  [Resource] ->
				      %% Same resource opened new session
				      true;
				  [] -> true;
				  _ -> false
			      end
		      end,
    ?DEBUG("Re-routing ~B unacknowledged stanza(s) to ~s",
	   [p1_queue:len(Queue), jid:encode(JID)]),
    p1_queue:foreach(
      fun({_, _Time, #presence{from = From}}) ->
	      ?DEBUG("Dropping presence stanza from ~s", [jid:encode(From)]);
	 ({_, _Time, #iq{} = El}) ->
	      Txt = <<"User session terminated">>,
	      ejabberd_router:route_error(
		El, xmpp:err_service_unavailable(Txt, Lang));
	 ({_, _Time, #message{from = From, meta = #{carbon_copy := true}}}) ->
	      %% XEP-0280 says: "When a receiving server attempts to deliver a
	      %% forked message, and that message bounces with an error for
	      %% any reason, the receiving server MUST NOT forward that error
	      %% back to the original sender."  Resending such a stanza could
	      %% easily lead to unexpected results as well.
	      ?DEBUG("Dropping forwarded message stanza from ~s",
		     [jid:encode(From)]);
	 ({_, Time, #message{} = Msg}) ->
	      case ejabberd_hooks:run_fold(message_is_archived,
					   LServer, false,
					   [State, Msg]) of
		  true ->
		      ?DEBUG("Dropping archived message stanza from ~s",
			     [jid:encode(xmpp:get_from(Msg))]);
		  false when ResendOnTimeout ->
		      NewEl = add_resent_delay_info(State, Msg, Time),
		      ejabberd_router:route(NewEl);
		  false ->
		      Txt = <<"User session terminated">>,
		      ejabberd_router:route_error(
			Msg, xmpp:err_service_unavailable(Txt, Lang))
	      end;
	 ({_, _Time, El}) ->
	      %% Raw element of type 'error' resulting from a validation error
	      %% We cannot pass it to the router, it will generate an error
	      ?DEBUG("Do not route raw element from ack queue: ~p", [El])
      end, Queue);
route_unacked_stanzas(_State) ->
    ok.

-spec inherit_session_state(state(), binary()) -> {ok, state()} |
						  {error, binary()} |
						  {error, binary(), non_neg_integer()}.
inherit_session_state(#{user := U, server := S,
			mgmt_queue_type := QueueType} = State, ResumeID) ->
    case misc:base64_to_term(ResumeID) of
	{term, {R, Time}} ->
	    case ejabberd_sm:get_session_pid(U, S, R) of
		none ->
		    case ejabberd_sm:get_offline_info(Time, U, S, R) of
			none ->
			    {error, <<"Previous session PID not found">>};
			Info ->
			    case proplists:get_value(num_stanzas_in, Info) of
				undefined ->
				    {error, <<"Previous session timed out">>};
				H ->
				    {error, <<"Previous session timed out">>, H}
			    end
		    end;
		OldPID ->
		    OldSID = {Time, OldPID},
		    try resume_session(OldSID, State) of
			{resume, #{mgmt_xmlns := Xmlns,
				   mgmt_queue := Queue,
				   mgmt_timeout := Timeout,
				   mgmt_stanzas_in := NumStanzasIn,
				   mgmt_stanzas_out := NumStanzasOut} = OldState} ->
			    State1 = ejabberd_c2s:copy_state(State, OldState),
			    Queue1 = case QueueType of
					 ram -> Queue;
					 _ -> p1_queue:ram_to_file(Queue)
				     end,
			    State2 = State1#{mgmt_xmlns => Xmlns,
					     mgmt_queue => Queue1,
					     mgmt_timeout => Timeout,
					     mgmt_stanzas_in => NumStanzasIn,
					     mgmt_stanzas_out => NumStanzasOut,
					     mgmt_state => active},
			    ejabberd_sm:close_session(OldSID, U, S, R),
			    State3 = ejabberd_c2s:open_session(State2),
			    ejabberd_c2s:stop(OldPID),
			    {ok, State3};
			{error, Msg} ->
			    {error, Msg}
		    catch exit:{noproc, _} ->
			    {error, <<"Previous session PID is dead">>};
			  exit:{normal, _} ->
			    {error, <<"Previous session PID has exited">>};
			  exit:{timeout, _} ->
			    ejabberd_sm:close_session(OldSID, U, S, R),
			    ejabberd_c2s:stop(OldPID),
			    {error, <<"Session state copying timed out">>}
		    end
	    end;
	_ ->
	    {error, <<"Invalid 'previd' value">>}
    end.

-spec resume_session({erlang:timestamp(), pid()}, state()) -> {resume, state()} |
							      {error, binary()}.
resume_session({Time, Pid}, _State) ->
    ejabberd_c2s:call(Pid, {resume_session, Time}, timer:seconds(15)).

-spec make_resume_id(state()) -> binary().
make_resume_id(#{sid := {Time, _}, resource := Resource}) ->
    misc:term_to_base64({Resource, Time}).

-spec add_resent_delay_info(state(), stanza(), erlang:timestamp()) -> stanza();
			   (state(), xmlel(), erlang:timestamp()) -> xmlel().
add_resent_delay_info(#{lserver := LServer}, El, Time)
  when is_record(El, message); is_record(El, presence) ->
    xmpp_util:add_delay_info(El, jid:make(LServer), Time, <<"Resent">>);
add_resent_delay_info(_State, El, _Time) ->
    %% TODO
    El.

-spec send(state(), xmpp_element()) -> state().
send(#{mod := Mod} = State, Pkt) ->
    Mod:send(State, Pkt).

-spec restart_pending_timer(state(), non_neg_integer()) -> state().
restart_pending_timer(#{mgmt_pending_timer := TRef} = State, NewTimeout) ->
    cancel_timer(TRef),
    NewTRef = erlang:start_timer(timer:seconds(NewTimeout), self(),
				 pending_timeout),
    State#{mgmt_pending_timer => NewTRef};
restart_pending_timer(State, _NewTimeout) ->
    State.

-spec cancel_ack_timer(state()) -> state().
cancel_ack_timer(#{mgmt_ack_timer := TRef} = State) ->
    cancel_timer(TRef),
    maps:remove(mgmt_ack_timer, State);
cancel_ack_timer(State) ->
    State.

-spec cancel_timer(reference()) -> ok.
cancel_timer(TRef) ->
    case erlang:cancel_timer(TRef) of
	false ->
	    receive {timeout, TRef, _} -> ok
	    after 0 -> ok
	    end;
	_ ->
	    ok
    end.

-spec bounce_message_queue() -> ok.
bounce_message_queue() ->
    receive {route, Pkt} ->
	    ejabberd_router:route(Pkt),
	    bounce_message_queue()
    after 0 ->
	    ok
    end.

-spec need_to_enqueue(state(), xmlel() | stanza()) -> {boolean(), state()}.
need_to_enqueue(State, Pkt) when ?is_stanza(Pkt) ->
    {not xmpp:get_meta(Pkt, mgmt_is_resent, false), State};
need_to_enqueue(#{mgmt_force_enqueue := true} = State, #xmlel{}) ->
    State1 = maps:remove(mgmt_force_enqueue, State),
    State2 = maps:remove(mgmt_is_resent, State1),
    {true, State2};
need_to_enqueue(State, _) ->
    {false, State}.

%%%===================================================================
%%% Configuration processing
%%%===================================================================
get_max_ack_queue(Host) ->
    gen_mod:get_module_opt(Host, ?MODULE, max_ack_queue).

get_configured_resume_timeout(Host) ->
    gen_mod:get_module_opt(Host, ?MODULE, resume_timeout).

get_max_resume_timeout(Host, ResumeTimeout) ->
    case gen_mod:get_module_opt(Host, ?MODULE, max_resume_timeout) of
	undefined -> ResumeTimeout;
	Max when Max >= ResumeTimeout -> Max;
	_ -> ResumeTimeout
    end.

get_ack_timeout(Host) ->
    case gen_mod:get_module_opt(Host, ?MODULE, ack_timeout) of
	infinity -> infinity;
	T -> timer:seconds(T)
    end.

get_resend_on_timeout(Host) ->
    gen_mod:get_module_opt(Host, ?MODULE, resend_on_timeout).

get_queue_type(Host) ->
    gen_mod:get_module_opt(Host, ?MODULE, queue_type).

mod_opt_type(max_ack_queue) ->
    fun(I) when is_integer(I), I > 0 -> I;
       (infinity) -> infinity
    end;
mod_opt_type(resume_timeout) ->
    fun(I) when is_integer(I), I >= 0 -> I end;
mod_opt_type(max_resume_timeout) ->
    fun(I) when is_integer(I), I >= 0 -> I;
       (undefined) -> undefined
    end;
mod_opt_type(ack_timeout) ->
    fun(I) when is_integer(I), I > 0 -> I;
       (infinity) -> infinity
    end;
mod_opt_type(resend_on_timeout) ->
    fun(B) when is_boolean(B) -> B;
       (if_offline) -> if_offline
    end;
mod_opt_type(queue_type) ->
    fun(ram) -> ram; (file) -> file end.

mod_options(Host) ->
    [{max_ack_queue, 5000},
     {resume_timeout, 300},
     {max_resume_timeout, undefined},
     {ack_timeout, 60},
     {resend_on_timeout, false},
     {queue_type, ejabberd_config:default_queue_type(Host)}].
