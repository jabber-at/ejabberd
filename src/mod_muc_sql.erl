%%%-------------------------------------------------------------------
%%% File    : mod_muc_sql.erl
%%% Author  : Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% Created : 13 Apr 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
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

-module(mod_muc_sql).

-compile([{parse_transform, ejabberd_sql_pt}]).

-behaviour(mod_muc).
-behaviour(mod_muc_room).

%% API
-export([init/2, store_room/5, restore_room/3, forget_room/3,
	 can_use_nick/4, get_rooms/2, get_nick/3, set_nick/4,
	 import/3, export/1]).
-export([register_online_room/4, unregister_online_room/4, find_online_room/3,
	 get_online_rooms/3, count_online_rooms/2, rsm_supported/0,
	 register_online_user/4, unregister_online_user/4,
	 count_online_rooms_by_user/3, get_online_rooms_by_user/3,
	 get_subscribed_rooms/3]).
-export([set_affiliation/6, set_affiliations/4, get_affiliation/5,
	 get_affiliations/3, search_affiliation/4]).

-include("jid.hrl").
-include("mod_muc.hrl").
-include("logger.hrl").
-include("ejabberd_sql_pt.hrl").

%%%===================================================================
%%% API
%%%===================================================================
init(Host, Opts) ->
    case gen_mod:ram_db_mod(Host, Opts, mod_muc) of
	?MODULE ->
	    clean_tables(Host);
	_ ->
	    ok
    end.

store_room(LServer, Host, Name, Opts, ChangesHints) ->
    {Subs, Opts2} = case lists:keytake(subscribers, 1, Opts) of
			{value, {subscribers, S}, OptN} -> {S, OptN};
			_ -> {[], Opts}
		    end,
    SOpts = misc:term_to_expr(Opts2),
    F = fun () ->
		?SQL_UPSERT_T(
                   "muc_room",
                   ["!name=%(Name)s",
                    "!host=%(Host)s",
                    "server_host=%(LServer)s",
                    "opts=%(SOpts)s"]),
                case ChangesHints of
                    Changes when is_list(Changes) ->
                        [change_room(Host, Name, Change) || Change <- Changes];
                    _ ->
                        ejabberd_sql:sql_query_t(
                          ?SQL("delete from muc_room_subscribers where "
                               "room=%(Name)s and host=%(Host)s")),
                        [change_room(Host, Name, {add_subscription, JID, Nick, Nodes})
                         || {JID, Nick, Nodes} <- Subs]
                end
	end,
    ejabberd_sql:sql_transaction(LServer, F).

change_room(Host, Room, {add_subscription, JID, Nick, Nodes}) ->
    SJID = jid:encode(JID),
    SNodes = misc:term_to_expr(Nodes),
    ?SQL_UPSERT_T(
       "muc_room_subscribers",
       ["!jid=%(SJID)s",
	"!host=%(Host)s",
	"!room=%(Room)s",
	"nick=%(Nick)s",
	"nodes=%(SNodes)s"]);
change_room(Host, Room, {del_subscription, JID}) ->
    SJID = jid:encode(JID),
    ejabberd_sql:sql_query_t(?SQL("delete from muc_room_subscribers where "
				  "room=%(Room)s and host=%(Host)s and jid=%(SJID)s"));
change_room(Host, Room, Change) ->
    ?ERROR_MSG("Unsupported change on room ~s@~s: ~p", [Room, Host, Change]).

restore_room(LServer, Host, Name) ->
    case catch ejabberd_sql:sql_query(
                 LServer,
                 ?SQL("select @(opts)s from muc_room where name=%(Name)s"
                      " and host=%(Host)s")) of
	{selected, [{Opts}]} ->
	    OptsD = ejabberd_sql:decode_term(Opts),
	    case catch ejabberd_sql:sql_query(
		LServer,
		?SQL("select @(jid)s, @(nick)s, @(nodes)s from muc_room_subscribers where room=%(Name)s"
		     " and host=%(Host)s")) of
		{selected, []} ->
		    OptsR = mod_muc:opts_to_binary(OptsD),
		    case lists:keymember(subscribers, 1, OptsD) of
			true ->
			    store_room(LServer, Host, Name, OptsR, undefined);
			_ ->
			    ok
		    end,
		    OptsR;
		{selected, Subs} ->
		    SubData = lists:map(
			     fun({Jid, Nick, Nodes}) ->
				 {jid:decode(Jid), Nick, ejabberd_sql:decode_term(Nodes)}
			     end, Subs),
		    Opts2 = lists:keystore(subscribers, 1, OptsD, {subscribers, SubData}),
		    mod_muc:opts_to_binary(Opts2);
		_ ->
		    error
	    end;
	_ ->
	    error
    end.

forget_room(LServer, Host, Name) ->
    F = fun () ->
		ejabberd_sql:sql_query_t(
                  ?SQL("delete from muc_room where name=%(Name)s"
                       " and host=%(Host)s")),
		ejabberd_sql:sql_query_t(
		    ?SQL("delete from muc_room_subscribers where room=%(Name)s"
                       " and host=%(Host)s"))
	end,
    ejabberd_sql:sql_transaction(LServer, F).

can_use_nick(LServer, Host, JID, Nick) ->
    SJID = jid:encode(jid:tolower(jid:remove_resource(JID))),
    case catch ejabberd_sql:sql_query(
                 LServer,
                 ?SQL("select @(jid)s from muc_registered "
                      "where nick=%(Nick)s"
                      " and host=%(Host)s")) of
	{selected, [{SJID1}]} -> SJID == SJID1;
	_ -> true
    end.

get_rooms(LServer, Host) ->
    case catch ejabberd_sql:sql_query(
                 LServer,
                 ?SQL("select @(name)s, @(opts)s from muc_room"
                      " where host=%(Host)s")) of
	{selected, RoomOpts} ->
	    case catch ejabberd_sql:sql_query(
		LServer,
		?SQL("select @(room)s, @(jid)s, @(nick)s, @(nodes)s from muc_room_subscribers"
		     " where host=%(Host)s")) of
		{selected, Subs} ->
		    SubsD = lists:foldl(
			fun({Room, Jid, Nick, Nodes}, Dict) ->
			    dict:append(Room, {jid:decode(Jid),
					       Nick, ejabberd_sql:decode_term(Nodes)}, Dict)
			end, dict:new(), Subs),
	    lists:map(
	      fun({Room, Opts}) ->
			    OptsD = ejabberd_sql:decode_term(Opts),
			    OptsD2 = case {dict:find(Room, SubsD), lists:keymember(subscribers, 1, OptsD)} of
					 {_, true} ->
					     store_room(LServer, Host, Room, mod_muc:opts_to_binary(OptsD), undefined),
					     OptsD;
					 {{ok, SubsI}, false} ->
					     lists:keystore(subscribers, 1, OptsD, {subscribers, SubsI});
					 _ ->
					     OptsD
			    end,
		      #muc_room{name_host = {Room, Host},
				      opts = mod_muc:opts_to_binary(OptsD2)}
	      end, RoomOpts);
	_Err ->
		    []
	    end;
	_Err ->
	    []
    end.

get_nick(LServer, Host, From) ->
    SJID = jid:encode(jid:tolower(jid:remove_resource(From))),
    case catch ejabberd_sql:sql_query(
                 LServer,
                 ?SQL("select @(nick)s from muc_registered where"
                      " jid=%(SJID)s and host=%(Host)s")) of
	{selected, [{Nick}]} -> Nick;
	_ -> error
    end.

set_nick(LServer, Host, From, Nick) ->
    JID = jid:encode(jid:tolower(jid:remove_resource(From))),
    F = fun () ->
		case Nick of
		    <<"">> ->
			ejabberd_sql:sql_query_t(
			  ?SQL("delete from muc_registered where"
                               " jid=%(JID)s and host=%(Host)s")),
			ok;
		    _ ->
			Allow = case ejabberd_sql:sql_query_t(
				       ?SQL("select @(jid)s from muc_registered"
                                            " where nick=%(Nick)s"
                                            " and host=%(Host)s")) of
				    {selected, [{J}]} -> J == JID;
				    _ -> true
				end,
			if Allow ->
				?SQL_UPSERT_T(
                                  "muc_registered",
                                  ["!jid=%(JID)s",
                                   "!host=%(Host)s",
                                   "server_host=%(LServer)s",
                                   "nick=%(Nick)s"]),
				ok;
			   true ->
				false
			end
		end
	end,
    ejabberd_sql:sql_transaction(LServer, F).

set_affiliation(_ServerHost, _Room, _Host, _JID, _Affiliation, _Reason) ->
    {error, not_implemented}.

set_affiliations(_ServerHost, _Room, _Host, _Affiliations) ->
    {error, not_implemented}.

get_affiliation(_ServerHost, _Room, _Host, _LUser, _LServer) ->
    {error, not_implemented}.

get_affiliations(_ServerHost, _Room, _Host) ->
    {error, not_implemented}.

search_affiliation(_ServerHost, _Room, _Host, _Affiliation) ->
    {error, not_implemented}.

register_online_room(ServerHost, Room, Host, Pid) ->
    PidS = misc:encode_pid(Pid),
    NodeS = erlang:atom_to_binary(node(Pid), latin1),
    case ?SQL_UPSERT(ServerHost,
		     "muc_online_room",
		     ["!name=%(Room)s",
		      "!host=%(Host)s",
                      "server_host=%(ServerHost)s",
		      "node=%(NodeS)s",
		      "pid=%(PidS)s"]) of
	ok ->
	    ok;
	Err ->
	    Err
    end.

unregister_online_room(ServerHost, Room, Host, Pid) ->
    %% TODO: report errors
    PidS = misc:encode_pid(Pid),
    NodeS = erlang:atom_to_binary(node(Pid), latin1),
    ejabberd_sql:sql_query(
      ServerHost,
      ?SQL("delete from muc_online_room where name=%(Room)s and "
	   "host=%(Host)s and node=%(NodeS)s and pid=%(PidS)s")).

find_online_room(ServerHost, Room, Host) ->
    case ejabberd_sql:sql_query(
	   ServerHost,
	   ?SQL("select @(pid)s, @(node)s from muc_online_room where "
		"name=%(Room)s and host=%(Host)s")) of
	{selected, [{PidS, NodeS}]} ->
	    try {ok, misc:decode_pid(PidS, NodeS)}
	    catch _:{bad_node, _} -> error
	    end;
	{selected, []} ->
	    error;
	_Err ->
	    error
    end.

count_online_rooms(ServerHost, Host) ->
    case ejabberd_sql:sql_query(
	   ServerHost,
	   ?SQL("select @(count(*))d from muc_online_room "
		"where host=%(Host)s")) of
	{selected, [{Num}]} ->
	    Num;
	_Err ->
	    0
    end.

get_online_rooms(ServerHost, Host, _RSM) ->
    case ejabberd_sql:sql_query(
	   ServerHost,
	   ?SQL("select @(name)s, @(pid)s, @(node)s from muc_online_room "
		"where host=%(Host)s")) of
	{selected, Rows} ->
	    lists:flatmap(
	      fun({Room, PidS, NodeS}) ->
		      try [{Room, Host, misc:decode_pid(PidS, NodeS)}]
		      catch _:{bad_node, _} -> []
		      end
	      end, Rows);
	_Err ->
	    []
    end.

rsm_supported() ->
    false.

register_online_user(ServerHost, {U, S, R}, Room, Host) ->
    NodeS = erlang:atom_to_binary(node(), latin1),
    case ?SQL_UPSERT(ServerHost, "muc_online_users",
		     ["!username=%(U)s",
		      "!server=%(S)s",
		      "!resource=%(R)s",
		      "!name=%(Room)s",
		      "!host=%(Host)s",
                      "server_host=%(ServerHost)s",
		      "node=%(NodeS)s"]) of
	ok ->
	    ok;
	Err ->
	    Err
    end.

unregister_online_user(ServerHost, {U, S, R}, Room, Host) ->
    %% TODO: report errors
    ejabberd_sql:sql_query(
      ServerHost,
      ?SQL("delete from muc_online_users where username=%(U)s and "
	   "server=%(S)s and resource=%(R)s and name=%(Room)s and "
	   "host=%(Host)s")).

count_online_rooms_by_user(ServerHost, U, S) ->
    case ejabberd_sql:sql_query(
	   ServerHost,
	   ?SQL("select @(count(*))d from muc_online_users where "
		"username=%(U)s and server=%(S)s")) of
	{selected, [{Num}]} ->
	    Num;
	_Err ->
	    0
    end.

get_online_rooms_by_user(ServerHost, U, S) ->
    case ejabberd_sql:sql_query(
	   ServerHost,
	   ?SQL("select @(name)s, @(host)s from muc_online_users where "
		"username=%(U)s and server=%(S)s")) of
	{selected, Rows} ->
	    Rows;
	_Err ->
	    []
    end.

export(_Server) ->
    [{muc_room,
      fun(Host, #muc_room{name_host = {Name, RoomHost}, opts = Opts}) ->
              case str:suffix(Host, RoomHost) of
                  true ->
                      SOpts = misc:term_to_expr(Opts),
                      [?SQL("delete from muc_room where name=%(Name)s"
                            " and host=%(RoomHost)s;"),
                       ?SQL_INSERT(
                          "muc_room",
                          ["name=%(Name)s",
                           "host=%(RoomHost)s",
                           "server_host=%(Host)s",
                           "opts=%(SOpts)s"])];
                  false ->
                      []
              end
      end},
     {muc_registered,
      fun(Host, #muc_registered{us_host = {{U, S}, RoomHost},
                                nick = Nick}) ->
              case str:suffix(Host, RoomHost) of
                  true ->
                      SJID = jid:encode(jid:make(U, S)),
                      [?SQL("delete from muc_registered where"
                            " jid=%(SJID)s and host=%(RoomHost)s;"),
                       ?SQL_INSERT(
                          "muc_registered",
                          ["jid=%(SJID)s",
                           "host=%(RoomHost)s",
                           "server_host=%(Host)s",
                           "nick=%(Nick)s"])];
                  false ->
                      []
              end
      end}].

import(_, _, _) ->
    ok.

get_subscribed_rooms(LServer, Host, Jid) ->
    JidS = jid:encode(Jid),
    case catch ejabberd_sql:sql_query(
	LServer,
	?SQL("select @(room)s, @(nodes)s from muc_room_subscribers where jid=%(JidS)s"
	     " and host=%(Host)s")) of
	{selected, Subs} ->
	    [{jid:make(Room, Host, <<>>), ejabberd_sql:decode_term(Nodes)} || {Room, Nodes} <- Subs];
	_Error ->
	    []
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================
clean_tables(ServerHost) ->
    NodeS = erlang:atom_to_binary(node(), latin1),
    ?DEBUG("Cleaning SQL muc_online_room table...", []),
    case ejabberd_sql:sql_query(
	   ServerHost,
	   ?SQL("delete from muc_online_room where node=%(NodeS)s")) of
	{updated, _} ->
	    ok;
	Err1 ->
	    ?ERROR_MSG("failed to clean 'muc_online_room' table: ~p", [Err1]),
	    Err1
    end,
    ?DEBUG("Cleaning SQL muc_online_users table...", []),
    case ejabberd_sql:sql_query(
	   ServerHost,
	   ?SQL("delete from muc_online_users where node=%(NodeS)s")) of
	{updated, _} ->
	    ok;
	Err2 ->
	    ?ERROR_MSG("failed to clean 'muc_online_users' table: ~p", [Err2]),
	    Err2
    end.
