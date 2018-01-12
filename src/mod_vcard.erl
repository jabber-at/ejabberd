%%%----------------------------------------------------------------------
%%% File    : mod_vcard.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Vcard management
%%% Created :  2 Jan 2003 by Alexey Shchepin <alexey@process-one.net>
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

-module(mod_vcard).

-author('alexey@process-one.net').

-protocol({xep, 54, '1.2'}).
-protocol({xep, 55, '1.3'}).

-behaviour(gen_server).
-behaviour(gen_mod).

-export([start/2, stop/1, get_sm_features/5,
	 process_local_iq/1, process_sm_iq/1, string2lower/1,
	 remove_user/2, export/1, import_info/0, import/5, import_start/2,
	 depends/2, process_search/1, process_vcard/1, get_vcard/2,
	 disco_items/5, disco_features/5, disco_identity/5,
	 vcard_iq_set/1, mod_opt_type/1, set_vcard/3, make_vcard_search/4]).
-export([init/1, handle_call/3, handle_cast/2,
	 handle_info/2, terminate/2, code_change/3]).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-include("mod_vcard.hrl").
-include("translate.hrl").

-define(JUD_MATCHES, 30).
-define(VCARD_CACHE, vcard_cache).

-callback init(binary(), gen_mod:opts()) -> any().
-callback stop(binary()) -> any().
-callback import(binary(), binary(), [binary()]) -> ok.
-callback get_vcard(binary(), binary()) -> {ok, [xmlel()]} | error.
-callback set_vcard(binary(), binary(),
		    xmlel(), #vcard_search{}) -> {atomic, any()}.
-callback search_fields(binary()) -> [{binary(), binary()}].
-callback search_reported(binary()) -> [{binary(), binary()}].
-callback search(binary(), [{binary(), [binary()]}], boolean(),
		 infinity | pos_integer()) -> [{binary(), binary()}].
-callback remove_user(binary(), binary()) -> {atomic, any()}.
-callback is_search_supported(binary()) -> boolean().
-callback use_cache(binary()) -> boolean().
-callback cache_nodes(binary()) -> [node()].

-optional_callbacks([use_cache/1, cache_nodes/1]).

-record(state, {hosts :: [binary()], server_host :: binary()}).

%%====================================================================
%% gen_mod callbacks
%%====================================================================
start(Host, Opts) ->
    gen_mod:start_child(?MODULE, Host, Opts).

stop(Host) ->
    gen_mod:stop_child(?MODULE, Host).

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([Host, Opts]) ->
    process_flag(trap_exit, true),
    Mod = gen_mod:db_mod(Host, Opts, ?MODULE),
    Mod:init(Host, Opts),
    init_cache(Mod, Host, Opts),
    ejabberd_hooks:add(remove_user, Host, ?MODULE,
		       remove_user, 50),
    IQDisc = gen_mod:get_opt(iqdisc, Opts, gen_iq_handler:iqdisc(Host)),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host,
				  ?NS_VCARD, ?MODULE, process_local_iq, IQDisc),
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host,
				  ?NS_VCARD, ?MODULE, process_sm_iq, IQDisc),
    ejabberd_hooks:add(disco_sm_features, Host, ?MODULE,
		       get_sm_features, 50),
    ejabberd_hooks:add(vcard_iq_set, Host, ?MODULE, vcard_iq_set, 50),
    MyHosts = gen_mod:get_opt_hosts(Host, Opts, <<"vjud.@HOST@">>),
    Search = gen_mod:get_opt(search, Opts, false),
    if Search ->
	    lists:foreach(
	      fun(MyHost) ->
		      ejabberd_hooks:add(
			disco_local_items, MyHost, ?MODULE, disco_items, 100),
		      ejabberd_hooks:add(
			disco_local_features, MyHost, ?MODULE, disco_features, 100),
		      ejabberd_hooks:add(
			disco_local_identity, MyHost, ?MODULE, disco_identity, 100),
		      gen_iq_handler:add_iq_handler(
			ejabberd_local, MyHost, ?NS_SEARCH, ?MODULE, process_search, IQDisc),
		      gen_iq_handler:add_iq_handler(
			ejabberd_local, MyHost, ?NS_VCARD, ?MODULE, process_vcard, IQDisc),
		      gen_iq_handler:add_iq_handler(
			ejabberd_local, MyHost, ?NS_DISCO_ITEMS, mod_disco,
			process_local_iq_items, IQDisc),
		      gen_iq_handler:add_iq_handler(
			ejabberd_local, MyHost, ?NS_DISCO_INFO, mod_disco,
			process_local_iq_info, IQDisc),
		      case Mod:is_search_supported(Host) of
			  false ->
			      ?WARNING_MSG("vcard search functionality is "
					   "not implemented for ~s backend",
					   [gen_mod:db_type(Host, Opts, ?MODULE)]);
			  true ->
			      ejabberd_router:register_route(MyHost, Host)
		      end
	      end, MyHosts);
       true ->
	    ok
    end,
    {ok, #state{hosts = MyHosts, server_host = Host}}.

handle_call(_Call, _From, State) ->
    {noreply, State}.

handle_cast(Cast, State) ->
    ?WARNING_MSG("unexpected cast: ~p", [Cast]),
    {noreply, State}.

handle_info({route, Packet}, State) ->
    case catch do_route(Packet) of
	{'EXIT', Reason} -> ?ERROR_MSG("~p", [Reason]);
	_ -> ok
    end,
    {noreply, State};
handle_info(Info, State) ->
    ?WARNING_MSG("unexpected info: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, #state{hosts = MyHosts, server_host = Host}) ->
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 50),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_VCARD),
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_VCARD),
    ejabberd_hooks:delete(disco_sm_features, Host, ?MODULE, get_sm_features, 50),
    ejabberd_hooks:delete(vcard_iq_set, Host, ?MODULE, vcard_iq_set, 50),
    Mod = gen_mod:db_mod(Host, ?MODULE),
    Mod:stop(Host),
    lists:foreach(
      fun(MyHost) ->
	      ejabberd_router:unregister_route(MyHost),
	      ejabberd_hooks:delete(disco_local_items, MyHost, ?MODULE, disco_items, 100),
	      ejabberd_hooks:delete(disco_local_features, MyHost, ?MODULE, disco_features, 100),
	      ejabberd_hooks:delete(disco_local_identity, MyHost, ?MODULE, disco_identity, 100),
	      gen_iq_handler:remove_iq_handler(ejabberd_local, MyHost, ?NS_SEARCH),
	      gen_iq_handler:remove_iq_handler(ejabberd_local, MyHost, ?NS_VCARD),
	      gen_iq_handler:remove_iq_handler(ejabberd_local, MyHost, ?NS_DISCO_ITEMS),
	      gen_iq_handler:remove_iq_handler(ejabberd_local, MyHost, ?NS_DISCO_INFO)
      end, MyHosts).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

do_route(#iq{} = IQ) ->
    ejabberd_router:process_iq(IQ);
do_route(_) ->
    ok.

-spec get_sm_features({error, stanza_error()} | empty | {result, [binary()]},
		      jid(), jid(), binary(), binary()) ->
			     {error, stanza_error()} | empty | {result, [binary()]}.
get_sm_features({error, _Error} = Acc, _From, _To,
		_Node, _Lang) ->
    Acc;
get_sm_features(Acc, _From, _To, Node, _Lang) ->
    case Node of
      <<"">> ->
	  case Acc of
	    {result, Features} ->
		{result, [?NS_DISCO_INFO, ?NS_VCARD | Features]};
	    empty -> {result, [?NS_DISCO_INFO, ?NS_VCARD]}
	  end;
      _ -> Acc
    end.

-spec process_local_iq(iq()) -> iq().
process_local_iq(#iq{type = set, lang = Lang} = IQ) ->
    Txt = <<"Value 'set' of 'type' attribute is not allowed">>,
    xmpp:make_error(IQ, xmpp:err_not_allowed(Txt, Lang));
process_local_iq(#iq{type = get, lang = Lang} = IQ) ->
    Desc = translate:translate(Lang, <<"Erlang Jabber Server">>),
    xmpp:make_iq_result(
      IQ, #vcard_temp{fn = <<"ejabberd">>,
		      url = ?EJABBERD_URI,
		      desc = <<Desc/binary, $\n, ?COPYRIGHT>>,
		      bday = <<"2002-11-16">>}).

-spec process_sm_iq(iq()) -> iq().
process_sm_iq(#iq{type = set, lang = Lang, from = From} = IQ) ->
    #jid{lserver = LServer} = From,
    case lists:member(LServer, ?MYHOSTS) of
	true ->
	    case ejabberd_hooks:run_fold(vcard_iq_set, LServer, IQ, []) of
		drop -> ignore;
		#stanza_error{} = Err -> xmpp:make_error(IQ, Err);
		_ -> xmpp:make_iq_result(IQ)
	    end;
	false ->
	    Txt = <<"The query is only allowed from local users">>,
	    xmpp:make_error(IQ, xmpp:err_not_allowed(Txt, Lang))
    end;
process_sm_iq(#iq{type = get, from = From, to = To, lang = Lang} = IQ) ->
    #jid{luser = LUser, lserver = LServer} = To,
    case get_vcard(LUser, LServer) of
	error ->
	    Txt = <<"Database failure">>,
	    xmpp:make_error(IQ, xmpp:err_internal_server_error(Txt, Lang));
	[] ->
	    xmpp:make_iq_result(IQ, #vcard_temp{});
	Els ->
	    IQ#iq{type = result, to = From, from = To, sub_els = Els}
    end.

-spec process_vcard(iq()) -> iq().
process_vcard(#iq{type = set, lang = Lang} = IQ) ->
    Txt = <<"Value 'set' of 'type' attribute is not allowed">>,
    xmpp:make_error(IQ, xmpp:err_not_allowed(Txt, Lang));
process_vcard(#iq{type = get, lang = Lang} = IQ) ->
    Desc = translate:translate(Lang, <<"ejabberd vCard module">>),
    xmpp:make_iq_result(
      IQ, #vcard_temp{fn = <<"ejabberd/mod_vcard">>,
		      url = ?EJABBERD_URI,
		      desc = <<Desc/binary, $\n, ?COPYRIGHT>>}).

-spec process_search(iq()) -> iq().
process_search(#iq{type = get, to = To, lang = Lang} = IQ) ->
    ServerHost = ejabberd_router:host_of_route(To#jid.lserver),
    xmpp:make_iq_result(IQ, mk_search_form(To, ServerHost, Lang));
process_search(#iq{type = set, to = To, lang = Lang,
		   sub_els = [#search{xdata = #xdata{type = submit,
						     fields = Fs}}]} = IQ) ->
    ServerHost = ejabberd_router:host_of_route(To#jid.lserver),
    ResultXData = search_result(Lang, To, ServerHost, Fs),
    xmpp:make_iq_result(IQ, #search{xdata = ResultXData});
process_search(#iq{type = set, lang = Lang} = IQ) ->
    Txt = <<"Incorrect data form">>,
    xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang)).

-spec disco_items({error, stanza_error()} | {result, [disco_item()]} | empty,
		  jid(), jid(), binary(), binary()) ->
			 {error, stanza_error()} | {result, [disco_item()]}.
disco_items(empty, _From, _To, <<"">>, _Lang) ->
    {result, []};
disco_items(empty, _From, _To, _Node, Lang) ->
    {error, xmpp:err_item_not_found(<<"No services available">>, Lang)};
disco_items(Acc, _From, _To, _Node, _Lang) ->
    Acc.

-spec disco_features({error, stanza_error()} | {result, [binary()]} | empty,
		     jid(), jid(), binary(), binary()) ->
			    {error, stanza_error()} | {result, [binary()]}.
disco_features({error, _Error} = Acc, _From, _To, _Node, _Lang) ->
    Acc;
disco_features(Acc, _From, _To, <<"">>, _Lang) ->
    Features = case Acc of
		   {result, Fs} -> Fs;
		   empty -> []
	       end,
    {result, [?NS_DISCO_INFO, ?NS_DISCO_ITEMS,
	      ?NS_VCARD, ?NS_SEARCH | Features]};
disco_features(empty, _From, _To, _Node, Lang) ->
    Txt = <<"No features available">>,
    {error, xmpp:err_item_not_found(Txt, Lang)};
disco_features(Acc, _From, _To, _Node, _Lang) ->
    Acc.

-spec disco_identity([identity()], jid(), jid(),
		     binary(),  binary()) -> [identity()].
disco_identity(Acc, _From, To, <<"">>, Lang) ->
    Host = ejabberd_router:host_of_route(To#jid.lserver),
    Name = gen_mod:get_module_opt(Host, ?MODULE, name, ?T("vCard User Search")),
    [#identity{category = <<"directory">>,
	       type = <<"user">>,
	       name = translate:translate(Lang, Name)}|Acc];
disco_identity(Acc, _From, _To, _Node, _Lang) ->
    Acc.

-spec get_vcard(binary(), binary()) -> [xmlel()] | error.
get_vcard(LUser, LServer) ->
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    Result = case use_cache(Mod, LServer) of
		 true ->
		     ets_cache:lookup(
		       ?VCARD_CACHE, {LUser, LServer},
		       fun() -> Mod:get_vcard(LUser, LServer) end);
		 false ->
		     Mod:get_vcard(LUser, LServer)
	     end,
    case Result of
	{ok, Els} -> Els;
	error -> error
    end.

-spec make_vcard_search(binary(), binary(), binary(), xmlel()) -> #vcard_search{}.
make_vcard_search(User, LUser, LServer, VCARD) ->
    FN = fxml:get_path_s(VCARD, [{elem, <<"FN">>}, cdata]),
    Family = fxml:get_path_s(VCARD,
			    [{elem, <<"N">>}, {elem, <<"FAMILY">>}, cdata]),
    Given = fxml:get_path_s(VCARD,
			   [{elem, <<"N">>}, {elem, <<"GIVEN">>}, cdata]),
    Middle = fxml:get_path_s(VCARD,
			    [{elem, <<"N">>}, {elem, <<"MIDDLE">>}, cdata]),
    Nickname = fxml:get_path_s(VCARD,
			      [{elem, <<"NICKNAME">>}, cdata]),
    BDay = fxml:get_path_s(VCARD,
			  [{elem, <<"BDAY">>}, cdata]),
    CTRY = fxml:get_path_s(VCARD,
			  [{elem, <<"ADR">>}, {elem, <<"CTRY">>}, cdata]),
    Locality = fxml:get_path_s(VCARD,
			      [{elem, <<"ADR">>}, {elem, <<"LOCALITY">>},
			       cdata]),
    EMail1 = fxml:get_path_s(VCARD,
			    [{elem, <<"EMAIL">>}, {elem, <<"USERID">>}, cdata]),
    EMail2 = fxml:get_path_s(VCARD,
			    [{elem, <<"EMAIL">>}, cdata]),
    OrgName = fxml:get_path_s(VCARD,
			     [{elem, <<"ORG">>}, {elem, <<"ORGNAME">>}, cdata]),
    OrgUnit = fxml:get_path_s(VCARD,
			     [{elem, <<"ORG">>}, {elem, <<"ORGUNIT">>}, cdata]),
    EMail = case EMail1 of
	      <<"">> -> EMail2;
	      _ -> EMail1
	    end,
    LFN = string2lower(FN),
    LFamily = string2lower(Family),
    LGiven = string2lower(Given),
    LMiddle = string2lower(Middle),
    LNickname = string2lower(Nickname),
    LBDay = string2lower(BDay),
    LCTRY = string2lower(CTRY),
    LLocality = string2lower(Locality),
    LEMail = string2lower(EMail),
    LOrgName = string2lower(OrgName),
    LOrgUnit = string2lower(OrgUnit),
    US = {LUser, LServer},
    #vcard_search{us = US,
		  user = {User, LServer},
		  luser = LUser, fn = FN,
		  lfn = LFN,
		  family = Family,
		  lfamily = LFamily,
		  given = Given,
		  lgiven = LGiven,
		  middle = Middle,
		  lmiddle = LMiddle,
		  nickname = Nickname,
		  lnickname = LNickname,
		  bday = BDay,
		  lbday = LBDay,
		  ctry = CTRY,
		  lctry = LCTRY,
		  locality = Locality,
		  llocality = LLocality,
		  email = EMail,
		  lemail = LEMail,
		  orgname = OrgName,
		  lorgname = LOrgName,
		  orgunit = OrgUnit,
		  lorgunit = LOrgUnit}.

-spec vcard_iq_set(iq()) -> iq() | {stop, stanza_error()}.
vcard_iq_set(#iq{from = From, lang = Lang, sub_els = [VCard]} = IQ) ->
    #jid{user = User, lserver = LServer} = From,
    case set_vcard(User, LServer, VCard) of
	{error, badarg} ->
	    %% Should not be here?
	    Txt = <<"Nodeprep has failed">>,
	    {stop, xmpp:err_internal_server_error(Txt, Lang)};
	ok ->
	    IQ
    end;
vcard_iq_set(Acc) ->
    Acc.

-spec set_vcard(binary(), binary(), xmlel() | vcard_temp()) -> {error, badarg} | ok.
set_vcard(User, LServer, VCARD) ->
    case jid:nodeprep(User) of
	error ->
	    {error, badarg};
	LUser ->
	    VCardEl = xmpp:encode(VCARD),
	    VCardSearch = make_vcard_search(User, LUser, LServer, VCardEl),
	    Mod = gen_mod:db_mod(LServer, ?MODULE),
	    Mod:set_vcard(LUser, LServer, VCardEl, VCardSearch),
	    ets_cache:delete(?VCARD_CACHE, {LUser, LServer},
			     cache_nodes(Mod, LServer)),
	    ok
    end.

-spec string2lower(binary()) -> binary().
string2lower(String) ->
    case stringprep:tolower(String) of
      Lower when is_binary(Lower) -> Lower;
      error -> str:to_lower(String)
    end.

-spec mk_tfield(binary(), binary(), binary()) -> xdata_field().
mk_tfield(Label, Var, Lang) ->
    #xdata_field{type = 'text-single',
		 label = translate:translate(Lang, Label),
		 var = Var}.

-spec mk_field(binary(), binary()) -> xdata_field().
mk_field(Var, Val) ->
    #xdata_field{var = Var, values = [Val]}.

-spec mk_search_form(jid(), binary(), binary()) -> search().
mk_search_form(JID, ServerHost, Lang) ->
    Title = <<(translate:translate(Lang, <<"Search users in ">>))/binary,
	      (jid:encode(JID))/binary>>,
    Mod = gen_mod:db_mod(ServerHost, ?MODULE),
    SearchFields = Mod:search_fields(ServerHost),
    Fs = [mk_tfield(Label, Var, Lang) || {Label, Var} <- SearchFields],
    X = #xdata{type = form,
	       title = Title,
	       instructions =
		   [translate:translate(
		      Lang,
		      <<"Fill in the form to search for any matching "
			"Jabber User (Add * to the end of field "
			"to match substring)">>)],
	       fields = Fs},
    #search{instructions =
		translate:translate(
		  Lang, <<"You need an x:data capable client to search">>),
	    xdata = X}.

-spec search_result(binary(), jid(), binary(), [xdata_field()]) -> xdata().
search_result(Lang, JID, ServerHost, XFields) ->
    Mod = gen_mod:db_mod(ServerHost, ?MODULE),
    Reported = [mk_tfield(Label, Var, Lang) ||
		   {Label, Var} <- Mod:search_reported(ServerHost)],
    #xdata{type = result,
	   title = <<(translate:translate(Lang,
					  <<"Search Results for ">>))/binary,
		     (jid:encode(JID))/binary>>,
	   reported = Reported,
	   items = lists:map(fun (Item) -> item_to_field(Item) end,
			     search(ServerHost, XFields))}.

-spec item_to_field([{binary(), binary()}]) -> [xdata_field()].
item_to_field(Items) ->
    [mk_field(Var, Value) || {Var, Value} <- Items].

-spec search(binary(), [xdata_field()]) -> [binary()].
search(LServer, XFields) ->
    Data = [{Var, Vals} || #xdata_field{var = Var, values = Vals} <- XFields],
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    AllowReturnAll = gen_mod:get_module_opt(LServer, ?MODULE, allow_return_all,
                                            false),
    MaxMatch = gen_mod:get_module_opt(LServer, ?MODULE, matches, ?JUD_MATCHES),
    Mod:search(LServer, Data, AllowReturnAll, MaxMatch).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec remove_user(binary(), binary()) -> ok.
remove_user(User, Server) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    Mod:remove_user(LUser, LServer),
    ets_cache:delete(?VCARD_CACHE, {LUser, LServer}, cache_nodes(Mod, LServer)).

-spec init_cache(module(), binary(), gen_mod:opts()) -> ok.
init_cache(Mod, Host, Opts) ->
    case use_cache(Mod, Host) of
	true ->
	    CacheOpts = cache_opts(Host, Opts),
	    ets_cache:new(?VCARD_CACHE, CacheOpts);
	false ->
	    ets_cache:delete(?VCARD_CACHE)
    end.

-spec cache_opts(binary(), gen_mod:opts()) -> [proplists:property()].
cache_opts(Host, Opts) ->
    MaxSize = gen_mod:get_opt(
		cache_size, Opts,
		ejabberd_config:cache_size(Host)),
    CacheMissed = gen_mod:get_opt(
		    cache_missed, Opts,
		    ejabberd_config:cache_missed(Host)),
    LifeTime = case gen_mod:get_opt(
		      cache_life_time, Opts,
		      ejabberd_config:cache_life_time(Host)) of
		   infinity -> infinity;
		   I -> timer:seconds(I)
	       end,
    [{max_size, MaxSize}, {cache_missed, CacheMissed}, {life_time, LifeTime}].

-spec use_cache(module(), binary()) -> boolean().
use_cache(Mod, Host) ->
    case erlang:function_exported(Mod, use_cache, 1) of
	true -> Mod:use_cache(Host);
	false ->
	    gen_mod:get_module_opt(
	      Host, ?MODULE, use_cache,
	      ejabberd_config:use_cache(Host))
    end.

-spec cache_nodes(module(), binary()) -> [node()].
cache_nodes(Mod, Host) ->
    case erlang:function_exported(Mod, cache_nodes, 1) of
	true -> Mod:cache_nodes(Host);
	false -> ejabberd_cluster:get_nodes()
    end.

import_info() ->
    [{<<"vcard">>, 3}, {<<"vcard_search">>, 24}].

import_start(LServer, DBType) ->
    Mod = gen_mod:db_mod(DBType, ?MODULE),
    Mod:init(LServer, []).

import(LServer, {sql, _}, DBType, Tab, L) ->
    Mod = gen_mod:db_mod(DBType, ?MODULE),
    Mod:import(LServer, Tab, L).

export(LServer) ->
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    Mod:export(LServer).

depends(_Host, _Opts) ->
    [].

mod_opt_type(allow_return_all) ->
    fun (B) when is_boolean(B) -> B end;
mod_opt_type(db_type) -> fun(T) -> ejabberd_config:v_db(?MODULE, T) end;
mod_opt_type(name) -> fun iolist_to_binary/1;
mod_opt_type(host) -> fun iolist_to_binary/1;
mod_opt_type(hosts) ->
    fun (L) -> lists:map(fun iolist_to_binary/1, L) end;
mod_opt_type(iqdisc) -> fun gen_iq_handler:check_type/1;
mod_opt_type(matches) ->
    fun (infinity) -> infinity;
	(I) when is_integer(I), I > 0 -> I
    end;
mod_opt_type(search) ->
    fun (B) when is_boolean(B) -> B end;
mod_opt_type(search_all_hosts) ->
    fun (B) when is_boolean(B) -> B end;
mod_opt_type(O) when O == cache_life_time; O == cache_size ->
    fun (I) when is_integer(I), I > 0 -> I;
        (infinity) -> infinity
    end;
mod_opt_type(O) when O == use_cache; O == cache_missed ->
    fun (B) when is_boolean(B) -> B end;
mod_opt_type(_) ->
    [allow_return_all, db_type, host, hosts, iqdisc, matches,
     search, search_all_hosts, cache_life_time, cache_size,
     use_cache, cache_missed, name].
