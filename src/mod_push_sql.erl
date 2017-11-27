%%%----------------------------------------------------------------------
%%% File    : mod_push_sql.erl
%%% Author  : Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% Purpose : 
%%% Created : 26 Oct 2017 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2017-2017   ProcessOne
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

-module(mod_push_sql).
-behaviour(mod_push).
-compile([{parse_transform, ejabberd_sql_pt}]).

%% API
-export([init/2, store_session/6, lookup_session/4, lookup_session/3,
	 lookup_sessions/3, lookup_sessions/2, lookup_sessions/1,
	 delete_session/3, delete_old_sessions/2, export/1]).

-include("xmpp.hrl").
-include("logger.hrl").
-include("ejabberd_sql_pt.hrl").
-include("mod_push.hrl").

%%%===================================================================
%%% API
%%%===================================================================
init(_Host, _Opts) ->
    ok.

store_session(LUser, LServer, NowTS, PushJID, Node, XData) ->
    XML = encode_xdata(XData),
    TS = misc:now_to_usec(NowTS),
    PushLJID = jid:tolower(PushJID),
    Service = jid:encode(PushLJID),
    case ?SQL_UPSERT(LServer, "push_session",
		     ["!username=%(LUser)s",
                      "!server_host=%(LServer)s",
		      "!timestamp=%(TS)d",
		      "!service=%(Service)s",
		      "!node=%(Node)s",
		      "xml=%(XML)s"]) of
	ok ->
	    {ok, {NowTS, PushLJID, Node, XData}};
	Err ->
	    ?ERROR_MSG("Failed to update 'push_session' table: ~p", [Err]),
	    {error, db_failure}
    end.

lookup_session(LUser, LServer, PushJID, Node) ->
    PushLJID = jid:tolower(PushJID),
    Service = jid:encode(PushLJID),
    case ejabberd_sql:sql_query(
	   LServer,
	   ?SQL("select @(timestamp)d, @(xml)s from push_session "
		"where username=%(LUser)s and %(LServer)H "
                "and service=%(Service)s "
		"and node=%(Node)s")) of
	{selected, [{TS, XML}]} ->
	    NowTS = misc:usec_to_now(TS),
	    XData = decode_xdata(XML, LUser, LServer),
	    {ok, {NowTS, PushLJID, Node, XData}};
	{selected, []} ->
	    {error, notfound};
	Err ->
	    ?ERROR_MSG("Failed to select from 'push_session' table: ~p", [Err]),
	    {error, db_failure}
    end.

lookup_session(LUser, LServer, NowTS) ->
    TS = misc:now_to_usec(NowTS),
    case ejabberd_sql:sql_query(
	   LServer,
	   ?SQL("select @(service)s, @(node)s, @(xml)s "
		"from push_session where username=%(LUser)s and %(LServer)H "
		"and timestamp=%(TS)d")) of
	{selected, [{Service, Node, XML}]} ->
	    PushLJID = jid:tolower(jid:decode(Service)),
	    XData = decode_xdata(XML, LUser, LServer),
	    {ok, {NowTS, PushLJID, Node, XData}};
	{selected, []} ->
	    {error, notfound};
	Err ->
	    ?ERROR_MSG("Failed to select from 'push_session' table: ~p", [Err]),
	    {error, db_failure}
    end.

lookup_sessions(LUser, LServer, PushJID) ->
    PushLJID = jid:tolower(PushJID),
    Service = jid:encode(PushLJID),
    case ejabberd_sql:sql_query(
	   LServer,
	   ?SQL("select @(timestamp)d, @(xml)s, @(node)s from push_session "
		"where username=%(LUser)s and %(LServer)H "
                "and service=%(Service)s")) of
	{selected, Rows} ->
	    {ok, lists:map(
		   fun({TS, XML, Node}) ->
			   NowTS = misc:usec_to_now(TS),
			   XData = decode_xdata(XML, LUser, LServer),
			   {NowTS, PushLJID, Node, XData}
		   end, Rows)};
	Err ->
	    ?ERROR_MSG("Failed to select from 'push_session' table: ~p", [Err]),
	    {error, db_failure}
    end.

lookup_sessions(LUser, LServer) ->
    case ejabberd_sql:sql_query(
	   LServer,
	   ?SQL("select @(timestamp)d, @(xml)s, @(node)s, @(service)s "
		"from push_session "
                "where username=%(LUser)s and %(LServer)H")) of
	{selected, Rows} ->
	    {ok, lists:map(
		   fun({TS, XML, Node, Service}) ->
			   NowTS = misc:usec_to_now(TS),
			   XData = decode_xdata(XML, LUser, LServer),
			   PushLJID = jid:tolower(jid:decode(Service)),
			   {NowTS, PushLJID,Node, XData}
		   end, Rows)};
	Err ->
	    ?ERROR_MSG("Failed to select from 'push_session' table: ~p", [Err]),
	    {error, db_failure}
    end.

lookup_sessions(LServer) ->
    case ejabberd_sql:sql_query(
	   LServer,
	   ?SQL("select @(username)s, @(timestamp)d, @(xml)s, "
		"@(node)s, @(service)s from push_session "
                "where %(LServer)H")) of
	{selected, Rows} ->
	    {ok, lists:map(
		   fun({LUser, TS, XML, Node, Service}) ->
			   NowTS = misc:usec_to_now(TS),
			   XData = decode_xdata(XML, LUser, LServer),
			   PushLJID = jid:tolower(jid:decode(Service)),
			   {NowTS, PushLJID, Node, XData}
		   end, Rows)};
	Err ->
	    ?ERROR_MSG("Failed to select from 'push_session' table: ~p", [Err]),
	    {error, db_failure}
    end.

delete_session(LUser, LServer, NowTS) ->
    TS = misc:now_to_usec(NowTS),
    case ejabberd_sql:sql_query(
	   LServer,
	   ?SQL("delete from push_session where "
		"username=%(LUser)s and %(LServer)H and timestamp=%(TS)d")) of
	{updated, _} ->
	    ok;
	Err ->
	    ?ERROR_MSG("failed to delete from 'push_session' table: ~p", [Err]),
	    {error, db_failure}
    end.

delete_old_sessions(LServer, Time) ->
    TS = misc:now_to_usec(Time),
    case ejabberd_sql:sql_query(
	   LServer,
	   ?SQL("delete from push_session where timestamp<%(TS)d "
                "and %(LServer)H")) of
	{updated, _} ->
	    ok;
	Err ->
	    ?ERROR_MSG("failed to delete from 'push_session' table: ~p", [Err]),
	    {error, db_failure}
    end.

export(_Server) ->
    [{push_session,
      fun(Host, #push_session{us = {LUser, LServer},
			      timestamp = NowTS,
			      service = PushLJID,
			      node = Node,
			      xml = XData})
	    when LServer == Host ->
	      TS = misc:now_to_usec(NowTS),
	      Service = jid:encode(PushLJID),
	      XML = encode_xdata(XData),
	      [?SQL("delete from push_session where "
		    "username=%(LUser)s and %(LServer)H and "
                    "timestamp=%(TS)d and "
		    "service=%(Service)s and node=%(Node)s and "
		    "xml=%(XML)s;"),
	       ?SQL_INSERT(
                  "push_session",
                  ["username=%(LUser)s",
                   "server_host=%(LServer)s",
                   "timestamp=%(TS)d",
                   "service=%(Service)s",
                   "node=%(Node)s",
                   "xml=%(XML)s"])];
	 (_Host, _R) ->
	      []
      end}].

%%%===================================================================
%%% Internal functions
%%%===================================================================
decode_xdata(<<>>, _LUser, _LServer) ->
    undefined;
decode_xdata(XML, LUser, LServer) ->
    case fxml_stream:parse_element(XML) of
	#xmlel{} = El ->
	    try xmpp:decode(El)
	    catch _:{xmpp_codec, Why} ->
		    ?ERROR_MSG("Failed to decode ~s for user ~s@~s "
			       "from table 'push_session': ~s",
			       [XML, LUser, LServer, xmpp:format_error(Why)]),
		    undefined
	    end;
	Err ->
	    ?ERROR_MSG("Failed to decode ~s for user ~s@~s from "
		       "table 'push_session': ~p",
		       [XML, LUser, LServer, Err]),
	    undefined
    end.

encode_xdata(undefined) ->
    <<>>;
encode_xdata(XData) ->
    fxml:element_to_binary(xmpp:encode(XData)).
