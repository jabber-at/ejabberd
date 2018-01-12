%%%-------------------------------------------------------------------
%%% File    : mod_roster_sql.erl
%%% Author  : Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% Created : 14 Apr 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
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

-module(mod_roster_sql).

-compile([{parse_transform, ejabberd_sql_pt}]).

-behaviour(mod_roster).

%% API
-export([init/2, read_roster_version/2, write_roster_version/4,
	 get_roster/2, get_roster_item/3, roster_subscribe/4,
	 read_subscription_and_groups/3, remove_user/2,
	 update_roster/4, del_roster/3, transaction/2,
	 import/3, export/1, raw_to_record/2]).

-include("mod_roster.hrl").
-include("ejabberd_sql_pt.hrl").
-include("logger.hrl").

%%%===================================================================
%%% API
%%%===================================================================
init(_Host, _Opts) ->
    ok.

read_roster_version(LUser, LServer) ->
    case ejabberd_sql:sql_query(
	   LServer,
	   ?SQL("select @(version)s from roster_version"
		" where username = %(LUser)s and %(LServer)H")) of
	{selected, [{Version}]} -> {ok, Version};
	{selected, []} -> error;
	_ -> {error, db_failure}
    end.

write_roster_version(LUser, LServer, InTransaction, Ver) ->
    if InTransaction ->
	    set_roster_version(LUser, LServer, Ver);
       true ->
	    transaction(
	      LServer,
	      fun () -> set_roster_version(LUser, LServer, Ver) end)
    end.

get_roster(LUser, LServer) ->
    case ejabberd_sql:sql_query(
	   LServer,
	   ?SQL("select @(username)s, @(jid)s, @(nick)s, @(subscription)s, "
		"@(ask)s, @(askmessage)s, @(server)s, @(subscribe)s, "
		"@(type)s from rosterusers "
                "where username=%(LUser)s and %(LServer)H")) of
        {selected, Items} when is_list(Items) ->
            JIDGroups = case get_roster_jid_groups(LServer, LUser) of
                            {selected, JGrps} when is_list(JGrps) ->
                                JGrps;
                            _ ->
				[]
                        end,
            GroupsDict = lists:foldl(fun({J, G}, Acc) ->
                                             dict:append(J, G, Acc)
                                     end,
                                     dict:new(), JIDGroups),
	    {ok, lists:flatmap(
		   fun(I) ->
			   case raw_to_record(LServer, I) of
			       %% Bad JID in database:
			       error -> [];
			       R ->
				   SJID = jid:encode(R#roster.jid),
				   Groups = case dict:find(SJID, GroupsDict) of
						{ok, Gs} -> Gs;
						error -> []
					    end,
				   [R#roster{groups = Groups}]
			   end
		   end, Items)};
        _ ->
	    error
    end.

roster_subscribe(_LUser, _LServer, _LJID, Item) ->
    ItemVals = record_to_row(Item),
    roster_subscribe(ItemVals).

transaction(LServer, F) ->
    ejabberd_sql:sql_transaction(LServer, F).

get_roster_item(LUser, LServer, LJID) ->
    SJID = jid:encode(LJID),
    case get_roster_by_jid(LServer, LUser, SJID) of
	{selected, [I]} ->
            case raw_to_record(LServer, I) of
		error ->
		    error;
		R ->
		    Groups = case get_roster_groups(LServer, LUser, SJID) of
				 {selected, JGrps} when is_list(JGrps) ->
				     [JGrp || {JGrp} <- JGrps];
				 _ -> []
			     end,
		    {ok, R#roster{groups = Groups}}
	    end;
	{selected, []} ->
	    error
    end.

remove_user(LUser, LServer) ->
    transaction(
      LServer,
      fun () ->
              ejabberd_sql:sql_query_t(
                ?SQL("delete from rosterusers"
                     " where username=%(LUser)s and %(LServer)H")),
              ejabberd_sql:sql_query_t(
                ?SQL("delete from rostergroups"
                     " where username=%(LUser)s and %(LServer)H"))
      end),
    ok.

update_roster(LUser, LServer, LJID, Item) ->
    SJID = jid:encode(LJID),
    ItemVals = record_to_row(Item),
    ItemGroups = Item#roster.groups,
    roster_subscribe(ItemVals),
    ejabberd_sql:sql_query_t(
      ?SQL("delete from rostergroups"
           " where username=%(LUser)s and %(LServer)H and jid=%(SJID)s")),
    lists:foreach(
      fun(ItemGroup) ->
              ejabberd_sql:sql_query_t(
                ?SQL_INSERT(
                   "rostergroups",
                   ["username=%(LUser)s",
                    "server_host=%(LServer)s",
                    "jid=%(SJID)s",
                    "grp=%(ItemGroup)s"]))
      end,
      ItemGroups).

del_roster(LUser, LServer, LJID) ->
    SJID = jid:encode(LJID),
    ejabberd_sql:sql_query_t(
      ?SQL("delete from rosterusers"
           " where username=%(LUser)s and %(LServer)H and jid=%(SJID)s")),
    ejabberd_sql:sql_query_t(
      ?SQL("delete from rostergroups"
           " where username=%(LUser)s and %(LServer)H and jid=%(SJID)s")).

read_subscription_and_groups(LUser, LServer, LJID) ->
    SJID = jid:encode(LJID),
    case get_subscription(LServer, LUser, SJID) of
	{selected, [{SSubscription}]} ->
	    Subscription = case SSubscription of
			       <<"B">> -> both;
			       <<"T">> -> to;
			       <<"F">> -> from;
			       <<"N">> -> none;
			       <<"">> -> none;
			       _ ->
				   ?ERROR_MSG("~s", [format_row_error(
						       LUser, LServer,
						       {subscription, SSubscription})]),
				   none
			   end,
	    Groups = case get_rostergroup_by_jid(LServer, LUser, SJID) of
			 {selected, JGrps} when is_list(JGrps) ->
			     [JGrp || {JGrp} <- JGrps];
			 _ -> []
		     end,
	    {ok, {Subscription, Groups}};
	_ ->
	    error
    end.

export(_Server) ->
    [{roster,
      fun(Host, #roster{usj = {_LUser, LServer, _LJID}} = R)
            when LServer == Host ->
              ItemVals = record_to_row(R),
              ItemGroups = R#roster.groups,
              update_roster_sql(ItemVals, ItemGroups);
        (_Host, _R) ->
              []
      end},
     {roster_version,
      fun(Host, #roster_version{us = {LUser, LServer}, version = Ver})
            when LServer == Host ->
              [?SQL("delete from roster_version"
                    " where username=%(LUser)s and %(LServer)H;"),
               ?SQL_INSERT(
                  "roster_version",
                  ["username=%(LUser)s",
                   "server_host=%(LServer)s",
                   "version=%(Ver)s"])];
         (_Host, _R) ->
              []
      end}].

import(_, _, _) ->
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================
set_roster_version(LUser, LServer, Version) ->
    ?SQL_UPSERT_T(
       "roster_version",
       ["!username=%(LUser)s",
        "!server_host=%(LServer)s",
        "version=%(Version)s"]).

get_roster_jid_groups(LServer, LUser) ->
    ejabberd_sql:sql_query(
      LServer,
      ?SQL("select @(jid)s, @(grp)s from rostergroups where "
           "username=%(LUser)s and %(LServer)H")).

get_roster_groups(LServer, LUser, SJID) ->
    ejabberd_sql:sql_query_t(
      ?SQL("select @(grp)s from rostergroups"
           " where username=%(LUser)s and %(LServer)H and jid=%(SJID)s")).

roster_subscribe({LUser, LServer, SJID, Name, SSubscription, SAsk, AskMessage}) ->
    ?SQL_UPSERT_T(
       "rosterusers",
       ["!username=%(LUser)s",
        "!server_host=%(LServer)s",
        "!jid=%(SJID)s",
        "nick=%(Name)s",
        "subscription=%(SSubscription)s",
        "ask=%(SAsk)s",
        "askmessage=%(AskMessage)s",
        "server='N'",
        "subscribe=''",
        "type='item'"]).

get_roster_by_jid(LServer, LUser, SJID) ->
    ejabberd_sql:sql_query_t(
      ?SQL("select @(username)s, @(jid)s, @(nick)s, @(subscription)s,"
           " @(ask)s, @(askmessage)s, @(server)s, @(subscribe)s,"
           " @(type)s from rosterusers"
           " where username=%(LUser)s and %(LServer)H and jid=%(SJID)s")).

get_rostergroup_by_jid(LServer, LUser, SJID) ->
    ejabberd_sql:sql_query(
      LServer,
      ?SQL("select @(grp)s from rostergroups"
           " where username=%(LUser)s and %(LServer)H and jid=%(SJID)s")).

get_subscription(LServer, LUser, SJID) ->
    ejabberd_sql:sql_query(
      LServer,
      ?SQL("select @(subscription)s from rosterusers "
           "where username=%(LUser)s and %(LServer)H and jid=%(SJID)s")).

update_roster_sql({LUser, LServer, SJID, Name, SSubscription, SAsk, AskMessage},
		  ItemGroups) ->
    [?SQL("delete from rosterusers where"
          " username=%(LUser)s and %(LServer)H and jid=%(SJID)s;"),
     ?SQL_INSERT(
        "rosterusers",
        ["username=%(LUser)s",
         "server_host=%(LServer)s",
         "jid=%(SJID)s",
         "nick=%(Name)s",
         "subscription=%(SSubscription)s",
         "ask=%(SAsk)s",
         "askmessage=%(AskMessage)s",
         "server='N'",
         "subscribe=''",
         "type='item'"]),
     ?SQL("delete from rostergroups where"
          " username=%(LUser)s and %(LServer)H and jid=%(SJID)s;")]
      ++
      [?SQL_INSERT(
          "rostergroups",
          ["username=%(LUser)s",
           "server_host=%(LServer)s",
           "jid=%(SJID)s",
           "grp=%(ItemGroup)s"])
       || ItemGroup <- ItemGroups].

raw_to_record(LServer,
	      [User, LServer, SJID, Nick, SSubscription, SAsk, SAskMessage,
	       _SServer, _SSubscribe, _SType]) ->
    raw_to_record(LServer,
                  {User, LServer, SJID, Nick, SSubscription, SAsk, SAskMessage,
                   _SServer, _SSubscribe, _SType});
raw_to_record(LServer,
	      {User, SJID, Nick, SSubscription, SAsk, SAskMessage,
	       _SServer, _SSubscribe, _SType}) ->
    raw_to_record(LServer,
                  {User, LServer, SJID, Nick, SSubscription, SAsk, SAskMessage,
                   _SServer, _SSubscribe, _SType});
raw_to_record(LServer,
	      {User, LServer, SJID, Nick, SSubscription, SAsk, SAskMessage,
	       _SServer, _SSubscribe, _SType}) ->
    try jid:decode(SJID) of
      JID ->
	  LJID = jid:tolower(JID),
	  Subscription = case SSubscription of
			     <<"B">> -> both;
			     <<"T">> -> to;
			     <<"F">> -> from;
			     <<"N">> -> none;
			     <<"">> -> none;
			     _ ->
				 ?ERROR_MSG("~s", [format_row_error(
						     User, LServer,
						     {subscription, SSubscription})]),
				 none
			 end,
	  Ask = case SAsk of
		    <<"S">> -> subscribe;
		    <<"U">> -> unsubscribe;
		    <<"B">> -> both;
		    <<"O">> -> out;
		    <<"I">> -> in;
		    <<"N">> -> none;
		    <<"">> -> none;
		    _ ->
			?ERROR_MSG("~s", [format_row_error(User, LServer, {ask, SAsk})]),
			none
		end,
	  #roster{usj = {User, LServer, LJID},
		  us = {User, LServer}, jid = LJID, name = Nick,
		  subscription = Subscription, ask = Ask,
		  askmessage = SAskMessage}
    catch _:{bad_jid, _} ->
	    ?ERROR_MSG("~s", [format_row_error(User, LServer, {jid, SJID})]),
	    error
    end.

record_to_row(
  #roster{us = {LUser, LServer},
          jid = JID, name = Name, subscription = Subscription,
          ask = Ask, askmessage = AskMessage}) ->
    SJID = jid:encode(jid:tolower(JID)),
    SSubscription = case Subscription of
		      both -> <<"B">>;
		      to -> <<"T">>;
		      from -> <<"F">>;
		      none -> <<"N">>
		    end,
    SAsk = case Ask of
	     subscribe -> <<"S">>;
	     unsubscribe -> <<"U">>;
	     both -> <<"B">>;
	     out -> <<"O">>;
	     in -> <<"I">>;
	     none -> <<"N">>
	   end,
    {LUser, LServer, SJID, Name, SSubscription, SAsk, AskMessage}.

format_row_error(User, Server, Why) ->
    [case Why of
	 {jid, JID} -> ["Malformed 'jid' field with value '", JID, "'"];
	 {subscription, Sub} -> ["Malformed 'subscription' field with value '", Sub, "'"];
	 {ask, Ask} -> ["Malformed 'ask' field with value '", Ask, "'"]
     end,
     " detected for ", User, "@", Server, " in table 'rosterusers'"].
