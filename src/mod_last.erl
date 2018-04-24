%%%----------------------------------------------------------------------
%%% File    : mod_last.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : jabber:iq:last support (XEP-0012)
%%% Created : 24 Oct 2003 by Alexey Shchepin <alexey@process-one.net>
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

-module(mod_last).

-author('alexey@process-one.net').

-protocol({xep, 12, '2.0'}).

-behaviour(gen_mod).

-export([start/2, stop/1, reload/3, process_local_iq/1, export/1,
	 process_sm_iq/1, on_presence_update/4, import_info/0,
	 import/5, import_start/2, store_last_info/4, get_last_info/2,
	 remove_user/2, mod_opt_type/1, mod_options/1,
	 register_user/2, depends/2, privacy_check_packet/4]).

-include("ejabberd.hrl").
-include("logger.hrl").

-include("xmpp.hrl").

-include("mod_privacy.hrl").
-include("mod_last.hrl").

-define(LAST_CACHE, last_activity_cache).

-callback init(binary(), gen_mod:opts()) -> any().
-callback import(binary(), #last_activity{}) -> ok | pass.
-callback get_last(binary(), binary()) ->
    {ok, {non_neg_integer(), binary()}} | error | {error, any()}.
-callback store_last_info(binary(), binary(), non_neg_integer(), binary()) -> ok | {error, any()}.
-callback remove_user(binary(), binary()) -> any().
-callback use_cache(binary()) -> boolean().
-callback cache_nodes(binary()) -> [node()].

-optional_callbacks([use_cache/1, cache_nodes/1]).

start(Host, Opts) ->
    Mod = gen_mod:db_mod(Host, Opts, ?MODULE),
    Mod:init(Host, Opts),
    init_cache(Mod, Host, Opts),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host,
				  ?NS_LAST, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host,
				  ?NS_LAST, ?MODULE, process_sm_iq),
    ejabberd_hooks:add(privacy_check_packet, Host, ?MODULE,
		       privacy_check_packet, 30),
    ejabberd_hooks:add(register_user, Host, ?MODULE,
		       register_user, 50),
    ejabberd_hooks:add(remove_user, Host, ?MODULE,
		       remove_user, 50),
    ejabberd_hooks:add(unset_presence_hook, Host, ?MODULE,
		       on_presence_update, 50).

stop(Host) ->
    ejabberd_hooks:delete(register_user, Host, ?MODULE,
			  register_user, 50),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE,
			  remove_user, 50),
    ejabberd_hooks:delete(unset_presence_hook, Host,
			  ?MODULE, on_presence_update, 50),
    ejabberd_hooks:delete(privacy_check_packet, Host, ?MODULE,
			  privacy_check_packet, 30),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host,
				     ?NS_LAST),
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host,
				     ?NS_LAST).

reload(Host, NewOpts, OldOpts) ->
    NewMod = gen_mod:db_mod(Host, NewOpts, ?MODULE),
    OldMod = gen_mod:db_mod(Host, OldOpts, ?MODULE),
    if NewMod /= OldMod ->
	    NewMod:init(Host, NewOpts);
       true ->
	    ok
    end,
    init_cache(NewMod, Host, NewOpts).

%%%
%%% Uptime of ejabberd node
%%%

-spec process_local_iq(iq()) -> iq().
process_local_iq(#iq{type = set, lang = Lang} = IQ) ->
    Txt = <<"Value 'set' of 'type' attribute is not allowed">>,
    xmpp:make_error(IQ, xmpp:err_not_allowed(Txt, Lang));
process_local_iq(#iq{type = get} = IQ) ->
    xmpp:make_iq_result(IQ, #last{seconds = get_node_uptime()}).

-spec get_node_uptime() -> non_neg_integer().
%% @doc Get the uptime of the ejabberd node, expressed in seconds.
%% When ejabberd is starting, ejabberd_config:start/0 stores the datetime.
get_node_uptime() ->
    case ejabberd_config:get_option(node_start) of
        undefined ->
            trunc(element(1, erlang:statistics(wall_clock)) / 1000);
        Now ->
            p1_time_compat:system_time(seconds) - Now
    end.

%%%
%%% Serve queries about user last online
%%%

-spec process_sm_iq(iq()) -> iq().
process_sm_iq(#iq{type = set, lang = Lang} = IQ) ->
    Txt = <<"Value 'set' of 'type' attribute is not allowed">>,
    xmpp:make_error(IQ, xmpp:err_not_allowed(Txt, Lang));
process_sm_iq(#iq{from = From, to = To, lang = Lang} = IQ) ->
    User = To#jid.luser,
    Server = To#jid.lserver,
    {Subscription, _Ask, _Groups} =
	ejabberd_hooks:run_fold(roster_get_jid_info, Server,
				{none, none, []}, [User, Server, From]),
    if (Subscription == both) or (Subscription == from) or
       (From#jid.luser == To#jid.luser) and
       (From#jid.lserver == To#jid.lserver) ->
	    Pres = xmpp:set_from_to(#presence{}, To, From),
	    case ejabberd_hooks:run_fold(privacy_check_packet,
					 Server, allow,
					 [To, Pres, out]) of
		allow -> get_last_iq(IQ, User, Server);
		deny -> xmpp:make_error(IQ, xmpp:err_forbidden())
	    end;
       true ->
	    Txt = <<"Not subscribed">>,
	    xmpp:make_error(IQ, xmpp:err_subscription_required(Txt, Lang))
    end.

privacy_check_packet(allow, C2SState,
		     #iq{from = From, to = To, type = T} = IQ, in)
  when T == get; T == set ->
    case xmpp:has_subtag(IQ, #last{}) of
	true ->
	    #jid{luser = LUser, lserver = LServer} = To,
	    {Sub, _, _} = ejabberd_hooks:run_fold(
			    roster_get_jid_info, LServer,
			    {none, none, []}, [LUser, LServer, From]),
	    if Sub == from; Sub == both ->
		    Pres = #presence{from = To, to = From},
		    case ejabberd_hooks:run_fold(
			   privacy_check_packet, allow,
			   [C2SState, Pres, out]) of
			allow ->
			    allow;
			deny ->
			    {stop, deny}
		    end;
	       true ->
		    {stop, deny}
	    end;
	false ->
	    allow
    end;
privacy_check_packet(Acc, _, _, _) ->
    Acc.

-spec get_last(binary(), binary()) -> {ok, non_neg_integer(), binary()} |
				      not_found | {error, any()}.
get_last(LUser, LServer) ->
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    Res = case use_cache(Mod, LServer) of
	      true ->
		  ets_cache:lookup(
		    ?LAST_CACHE, {LUser, LServer},
		    fun() -> Mod:get_last(LUser, LServer) end);
	      false ->
		  Mod:get_last(LUser, LServer);
	      undefined ->
		  error
	  end,
    case Res of
	{ok, {TimeStamp, Status}} -> {ok, TimeStamp, Status};
	error -> not_found;
	Err -> Err
    end.

-spec get_last_iq(iq(), binary(), binary()) -> iq().
get_last_iq(#iq{lang = Lang} = IQ, LUser, LServer) ->
    case ejabberd_sm:get_user_resources(LUser, LServer) of
      [] ->
	  case get_last(LUser, LServer) of
	    {error, _Reason} ->
		Txt = <<"Database failure">>,
		xmpp:make_error(IQ, xmpp:err_internal_server_error(Txt, Lang));
	    not_found ->
		Txt = <<"No info about last activity found">>,
		xmpp:make_error(IQ, xmpp:err_service_unavailable(Txt, Lang));
	    {ok, TimeStamp, Status} ->
		TimeStamp2 = p1_time_compat:system_time(seconds),
		Sec = TimeStamp2 - TimeStamp,
		xmpp:make_iq_result(IQ, #last{seconds = Sec, status = Status})
	  end;
      _ ->
	  xmpp:make_iq_result(IQ, #last{seconds = 0})
    end.

-spec register_user(binary(), binary()) -> any().
register_user(User, Server) ->
    on_presence_update(
       User,
       Server,
       <<"RegisterResource">>,
       <<"Registered but didn't login">>).

-spec on_presence_update(binary(), binary(), binary(), binary()) -> any().
on_presence_update(User, Server, _Resource, Status) ->
    TimeStamp = p1_time_compat:system_time(seconds),
    store_last_info(User, Server, TimeStamp, Status).

-spec store_last_info(binary(), binary(), non_neg_integer(), binary()) -> any().
store_last_info(User, Server, TimeStamp, Status) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    case use_cache(Mod, LServer) of
	true ->
	    ets_cache:update(
	      ?LAST_CACHE, {LUser, LServer}, {ok, {TimeStamp, Status}},
	      fun() ->
		      Mod:store_last_info(LUser, LServer, TimeStamp, Status)
	      end, cache_nodes(Mod, LServer));
	false ->
	    Mod:store_last_info(LUser, LServer, TimeStamp, Status)
    end.

-spec get_last_info(binary(), binary()) -> {ok, non_neg_integer(), binary()} |
					   not_found.
get_last_info(LUser, LServer) ->
    case get_last(LUser, LServer) of
      {error, _Reason} -> not_found;
      Res -> Res
    end.

-spec remove_user(binary(), binary()) -> any().
remove_user(User, Server) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    Mod:remove_user(LUser, LServer),
    ets_cache:delete(?LAST_CACHE, {LUser, LServer}, cache_nodes(Mod, LServer)).

-spec init_cache(module(), binary(), gen_mod:opts()) -> ok.
init_cache(Mod, Host, Opts) ->
    case use_cache(Mod, Host) of
	true ->
	    CacheOpts = cache_opts(Opts),
	    ets_cache:new(?LAST_CACHE, CacheOpts);
	false ->
	    ets_cache:delete(?LAST_CACHE)
    end.

-spec cache_opts(gen_mod:opts()) -> [proplists:property()].
cache_opts(Opts) ->
    MaxSize = gen_mod:get_opt(cache_size, Opts),
    CacheMissed = gen_mod:get_opt(cache_missed, Opts),
    LifeTime = case gen_mod:get_opt(cache_life_time, Opts) of
		   infinity -> infinity;
		   I -> timer:seconds(I)
	       end,
    [{max_size, MaxSize}, {cache_missed, CacheMissed}, {life_time, LifeTime}].

-spec use_cache(module(), binary()) -> boolean().
use_cache(Mod, Host) ->
    case erlang:function_exported(Mod, use_cache, 1) of
	true -> Mod:use_cache(Host);
	false -> gen_mod:get_module_opt(Host, ?MODULE, use_cache)
    end.

-spec cache_nodes(module(), binary()) -> [node()].
cache_nodes(Mod, Host) ->
    case erlang:function_exported(Mod, cache_nodes, 1) of
	true -> Mod:cache_nodes(Host);
	false -> ejabberd_cluster:get_nodes()
    end.

import_info() ->
    [{<<"last">>, 3}].

import_start(LServer, DBType) ->
    Mod = gen_mod:db_mod(DBType, ?MODULE),
    Mod:init(LServer, []).

import(LServer, {sql, _}, DBType, <<"last">>, [LUser, TimeStamp, State]) ->
    TS = case TimeStamp of
             <<"">> -> 0;
             _ -> binary_to_integer(TimeStamp)
         end,
    LA = #last_activity{us = {LUser, LServer},
                        timestamp = TS,
                        status = State},
    Mod = gen_mod:db_mod(DBType, ?MODULE),
    Mod:import(LServer, LA).

export(LServer) ->
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    Mod:export(LServer).

depends(_Host, _Opts) ->
    [].

mod_opt_type(db_type) -> fun(T) -> ejabberd_config:v_db(?MODULE, T) end;
mod_opt_type(O) when O == cache_life_time; O == cache_size ->
    fun (I) when is_integer(I), I > 0 -> I;
        (infinity) -> infinity
    end;
mod_opt_type(O) when O == use_cache; O == cache_missed ->
    fun (B) when is_boolean(B) -> B end.

mod_options(Host) ->
    [{db_type, ejabberd_config:default_db(Host, ?MODULE)},
     {use_cache, ejabberd_config:use_cache(Host)},
     {cache_size, ejabberd_config:cache_size(Host)},
     {cache_missed, ejabberd_config:cache_missed(Host)},
     {cache_life_time, ejabberd_config:cache_life_time(Host)}].
