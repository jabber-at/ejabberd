%%%----------------------------------------------------------------------
%%% File    : mod_push_mnesia.erl
%%% Author  : Holger Weiss <holger@zedat.fu-berlin.de>
%%% Purpose : Mnesia backend for Push Notifications (XEP-0357)
%%% Created : 15 Jul 2017 by Holger Weiss <holger@zedat.fu-berlin.de>
%%%
%%%
%%% ejabberd, Copyright (C) 2017   ProcessOne
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

-module(mod_push_mnesia).
-author('holger@zedat.fu-berlin.de').

-behavior(mod_push).

%% API
-export([init/2, store_session/6, lookup_session/4, lookup_session/3,
	 lookup_sessions/3, lookup_sessions/2, lookup_sessions/1,
	 delete_session/3, delete_old_sessions/2]).

-include_lib("stdlib/include/ms_transform.hrl").
-include("logger.hrl").
-include("xmpp.hrl").

-record(push_session,
	{us = {<<"">>, <<"">>}                  :: {binary(), binary()},
	 timestamp = p1_time_compat:timestamp() :: erlang:timestamp(),
	 service = {<<"">>, <<"">>, <<"">>}     :: ljid(),
	 node = <<"">>                          :: binary(),
	 xdata = #xdata{}                       :: xdata()}).

%%%-------------------------------------------------------------------
%%% API
%%%-------------------------------------------------------------------
init(_Host, _Opts) ->
    ejabberd_mnesia:create(?MODULE, push_session,
			   [{disc_only_copies, [node()]},
			    {type, bag},
			    {attributes, record_info(fields, push_session)}]).

store_session(LUser, LServer, TS, PushJID, Node, XData) ->
    US = {LUser, LServer},
    PushLJID = jid:tolower(PushJID),
    MaxSessions = ejabberd_sm:get_max_user_sessions(LUser, LServer),
    F = fun() ->
		if is_integer(MaxSessions) ->
			enforce_max_sessions(US, MaxSessions - 1);
		   MaxSessions == infinity ->
			ok
		end,
		mnesia:write(#push_session{us = US,
					   timestamp = TS,
					   service = PushLJID,
					   node = Node,
					   xdata = XData})
	end,
    case mnesia:transaction(F) of
	{atomic, ok} ->
	    {ok, {TS, PushLJID, Node, XData}};
	{aborted, E} ->
	    ?ERROR_MSG("Cannot store push session for ~s@~s: ~p",
		       [LUser, LServer, E]),
	    error
    end.

lookup_session(LUser, LServer, PushJID, Node) ->
    PushLJID = jid:tolower(PushJID),
    MatchSpec = ets:fun2ms(
		  fun(#push_session{us = {U, S}, service = P, node = N} = Rec)
			when U == LUser,
			     S == LServer,
			     P == PushLJID,
			     N == Node ->
			  Rec
		  end),
    case mnesia:dirty_select(push_session, MatchSpec) of
	[#push_session{timestamp = TS, xdata = XData}] ->
	    {ok, {TS, PushLJID, Node, XData}};
	_ ->
	    ?DEBUG("No push session found for ~s@~s (~p, ~s)",
		   [LUser, LServer, PushJID, Node]),
	    error
    end.

lookup_session(LUser, LServer, TS) ->
    MatchSpec = ets:fun2ms(
		  fun(#push_session{us = {U, S}, timestamp = T} = Rec)
			when U == LUser,
			     S == LServer,
			     T == TS ->
			  Rec
		  end),
    case mnesia:dirty_select(push_session, MatchSpec) of
	[#push_session{service = PushLJID, node = Node, xdata = XData}] ->
	    {ok, {TS, PushLJID, Node, XData}};
	_ ->
	    ?DEBUG("No push session found for ~s@~s (~p)",
		   [LUser, LServer, TS]),
	    error
    end.

lookup_sessions(LUser, LServer, PushJID) ->
    PushLJID = jid:tolower(PushJID),
    MatchSpec = ets:fun2ms(
		  fun(#push_session{us = {U, S}, service = P, node = N} = Rec)
			when U == LUser,
			     S == LServer,
			     P == PushLJID ->
			  Rec
		  end),
    {ok, mnesia:dirty_select(push_session, MatchSpec)}.

lookup_sessions(LUser, LServer) ->
    Records = mnesia:dirty_read(push_session, {LUser, LServer}),
    Clients = [{TS, PushLJID, Node, XData}
	       || #push_session{timestamp = TS,
				service = PushLJID,
				node = Node,
				xdata = XData} <- Records],
    {ok, Clients}.

lookup_sessions(LServer) ->
    MatchSpec = ets:fun2ms(
		  fun(#push_session{us = {_U, S},
				    timestamp = TS,
				    service = PushLJID,
				    node = Node,
				    xdata = XData})
			when S == LServer ->
			  {TS, PushLJID, Node, XData}
		  end),
    {ok, mnesia:dirty_select(push_session, MatchSpec)}.

delete_session(LUser, LServer, TS) ->
    MatchSpec = ets:fun2ms(
		  fun(#push_session{us = {U, S}, timestamp = T} = Rec)
			when U == LUser,
			     S == LServer,
			     T == TS ->
			  Rec
		  end),
    F = fun() ->
		Recs = mnesia:select(push_session, MatchSpec),
		lists:foreach(fun mnesia:delete_object/1, Recs)
	end,
    case mnesia:transaction(F) of
	{atomic, ok} ->
	    ok;
	{aborted, E} ->
	    ?ERROR_MSG("Cannot delete push session of ~s@~s: ~p",
		       [LUser, LServer, E]),
	    error
    end.

delete_old_sessions(_LServer, Time) ->
    DelIfOld = fun(#push_session{timestamp = T} = Rec, ok) when T < Time ->
		       mnesia:delete_object(Rec);
		  (_Rec, ok) ->
		       ok
	       end,
    F = fun() ->
		mnesia:foldl(DelIfOld, ok, push_session)
	end,
    case mnesia:transaction(F) of
	{atomic, ok} ->
	    ok;
	{aborted, E} ->
	    ?ERROR_MSG("Cannot delete old push sessions: ~p", [E]),
	    error
    end.

%%--------------------------------------------------------------------
%% Internal functions.
%%--------------------------------------------------------------------
-spec enforce_max_sessions({binary(), binary()}, non_neg_integer()) -> ok.
enforce_max_sessions({U, S} = US, Max) ->
    Recs = mnesia:wread({push_session, US}),
    NumRecs = length(Recs),
    if NumRecs > Max ->
	    NumOldRecs = NumRecs - Max,
	    Recs1 = lists:keysort(#push_session.timestamp, Recs),
	    Recs2 = lists:reverse(Recs1),
	    OldRecs = lists:sublist(Recs2, Max + 1, NumOldRecs),
	    ?INFO_MSG("Disabling ~B old push session(s) of ~s@~s",
		      [NumOldRecs, U, S]),
	    lists:foreach(fun(Rec) -> mnesia:delete_object(Rec) end, OldRecs);
       true ->
	    ok
    end.
