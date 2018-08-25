%%%-------------------------------------------------------------------
%%% File    : mod_delegation.erl
%%% Author  : Anna Mukharram <amuhar3@gmail.com>
%%% Purpose : XEP-0355: Namespace Delegation
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
-module(mod_delegation).

-author('amuhar3@gmail.com').

-protocol({xep, 0355, '0.3'}).

-behaviour(gen_server).
-behaviour(gen_mod).

%% API
-export([start/2, stop/1, reload/3, mod_opt_type/1, depends/2, mod_options/1]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).
-export([component_connected/1, component_disconnected/2,
	 ejabberd_local/1, ejabberd_sm/1, decode_iq_subel/1,
	 disco_local_features/5, disco_sm_features/5,
	 disco_local_identity/5, disco_sm_identity/5]).

-include("logger.hrl").
-include("xmpp.hrl").

-type disco_acc() :: {error, stanza_error()} | {result, [binary()]} | empty.
-record(state, {server_host = <<"">> :: binary(),
		delegations = dict:new() :: dict:dict()}).
-type state() :: #state{}.

%%%===================================================================
%%% API
%%%===================================================================
start(Host, Opts) ->
    gen_mod:start_child(?MODULE, Host, Opts).

stop(Host) ->
    gen_mod:stop_child(?MODULE, Host).

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_opt_type(namespaces) ->
    fun(L) ->
	    lists:map(
	      fun({NS, Opts}) ->
		      Attrs = proplists:get_value(filtering, Opts, []),
		      Access = proplists:get_value(access, Opts, none),
		      {NS, Attrs, Access}
	      end, L)
    end.

mod_options(_Host) ->
    [{namespaces, []}].

depends(_, _) ->
    [].

-spec decode_iq_subel(xmpp_element() | xmlel()) -> xmpp_element() | xmlel().
%% Tell gen_iq_handler not to auto-decode IQ payload
decode_iq_subel(El) ->
    El.

-spec component_connected(binary()) -> ok.
component_connected(Host) ->
    lists:foreach(
      fun(ServerHost) ->
	      Proc = gen_mod:get_module_proc(ServerHost, ?MODULE),
	      gen_server:cast(Proc, {component_connected, Host})
      end, ejabberd_config:get_myhosts()).

-spec component_disconnected(binary(), binary()) -> ok.
component_disconnected(Host, _Reason) ->
    lists:foreach(
      fun(ServerHost) ->
	      Proc = gen_mod:get_module_proc(ServerHost, ?MODULE),
	      gen_server:cast(Proc, {component_disconnected, Host})
      end, ejabberd_config:get_myhosts()).

-spec ejabberd_local(iq()) -> iq().
ejabberd_local(IQ) ->
    process_iq(IQ, ejabberd_local).

-spec ejabberd_sm(iq()) -> iq().
ejabberd_sm(IQ) ->
    process_iq(IQ, ejabberd_sm).

-spec disco_local_features(disco_acc(), jid(), jid(), binary(), binary()) -> disco_acc().
disco_local_features(Acc, From, To, Node, Lang) ->
    disco_features(Acc, From, To, Node, Lang, ejabberd_local).

-spec disco_sm_features(disco_acc(), jid(), jid(), binary(), binary()) -> disco_acc().
disco_sm_features(Acc, From, To, Node, Lang) ->
    disco_features(Acc, From, To, Node, Lang, ejabberd_sm).

-spec disco_local_identity(disco_acc(), jid(), jid(), binary(), binary()) -> disco_acc().
disco_local_identity(Acc, From, To, Node, Lang) ->
    disco_identity(Acc, From, To, Node, Lang, ejabberd_local).

-spec disco_sm_identity(disco_acc(), jid(), jid(), binary(), binary()) -> disco_acc().
disco_sm_identity(Acc, From, To, Node, Lang) ->
    disco_identity(Acc, From, To, Node, Lang, ejabberd_sm).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([Host, _Opts]) ->
    process_flag(trap_exit, true),
    ejabberd_hooks:add(component_connected, ?MODULE,
		       component_connected, 50),
    ejabberd_hooks:add(component_disconnected, ?MODULE,
		       component_disconnected, 50),
    ejabberd_hooks:add(disco_local_features, Host, ?MODULE,
		       disco_local_features, 50),
    ejabberd_hooks:add(disco_sm_features, Host, ?MODULE,
		       disco_sm_features, 50),
    ejabberd_hooks:add(disco_local_identity, Host, ?MODULE,
		       disco_local_identity, 50),
    ejabberd_hooks:add(disco_sm_identity, Host, ?MODULE,
		       disco_sm_identity, 50),
    {ok, #state{server_host = Host}}.

handle_call(get_delegations, _From, State) ->
    {reply, {ok, State#state.delegations}, State};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast({component_connected, Host}, State) ->
    ServerHost = State#state.server_host,
    To = jid:make(Host),
    NSAttrsAccessList = gen_mod:get_module_opt(
			  ServerHost, ?MODULE, namespaces),
    lists:foreach(
      fun({NS, _Attrs, Access}) ->
	      case acl:match_rule(ServerHost, Access, To) of
		  allow ->
		      send_disco_queries(ServerHost, Host, NS);
		  deny ->
		      ok
	      end
      end, NSAttrsAccessList),
    {noreply, State};
handle_cast({component_disconnected, Host}, State) ->
    ServerHost = State#state.server_host,
    Delegations =
	dict:filter(
	  fun({NS, Type}, {H, _}) when H == Host ->
		  ?INFO_MSG("Remove delegation of namespace '~s' "
			    "from external component '~s'",
			    [NS, Host]),
		  gen_iq_handler:remove_iq_handler(Type, ServerHost, NS),
		  false;
	     (_, _) ->
		  true
	  end, State#state.delegations),
    {noreply, State#state{delegations = Delegations}};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({iq_reply, ResIQ, {disco_info, Type, Host, NS}}, State) ->
    {noreply,
     case ResIQ of
	 #iq{type = result, sub_els = [SubEl]} ->
	     try xmpp:decode(SubEl) of
		 #disco_info{} = Info ->
		     process_disco_info(State, Type, Host, NS, Info)
		 catch _:{xmpp_codec, _} ->
			 State
		 end;
	 _ ->
	     State
     end};
handle_info({iq_reply, ResIQ, #iq{} = IQ}, State) ->
    process_iq_result(IQ, ResIQ),
    {noreply, State};
handle_info(Info, State) ->
    ?WARNING_MSG("unexpected info: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, State) ->
    %% Note: we don't remove component_* hooks because they are global
    %% and might be registered within a module on another virtual host
    ServerHost = State#state.server_host,
    ejabberd_hooks:delete(disco_local_features, ServerHost, ?MODULE,
			  disco_local_features, 50),
    ejabberd_hooks:delete(disco_sm_features, ServerHost, ?MODULE,
			  disco_sm_features, 50),
    ejabberd_hooks:delete(disco_local_identity, ServerHost, ?MODULE,
			  disco_local_identity, 50),
    ejabberd_hooks:delete(disco_sm_identity, ServerHost, ?MODULE,
			  disco_sm_identity, 50),
    lists:foreach(
      fun({NS, Type}) ->
	      gen_iq_handler:remove_iq_handler(Type, ServerHost, NS)
      end, dict:fetch_keys(State#state.delegations)).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
-spec get_delegations(binary()) -> dict:dict().
get_delegations(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?MODULE),
    try gen_server:call(Proc, get_delegations) of
	{ok, Delegations} -> Delegations
    catch exit:{noproc, _} ->
	    %% No module is loaded for this virtual host
	    dict:new()
    end.

-spec process_iq(iq(), ejabberd_local | ejabberd_sm) -> ignore | iq().
process_iq(#iq{to = To, lang = Lang, sub_els = [SubEl]} = IQ, Type) ->
    LServer = To#jid.lserver,
    NS = xmpp:get_ns(SubEl),
    Delegations = get_delegations(LServer),
    case dict:find({NS, Type}, Delegations) of
	{ok, {Host, _}} ->
	    Delegation = #delegation{
			    forwarded = #forwarded{sub_els = [IQ]}},
	    NewFrom = jid:make(LServer),
	    NewTo = jid:make(Host),
	    ejabberd_router:route_iq(
	      #iq{type = set,
		  from = NewFrom,
		  to = NewTo,
		  sub_els = [Delegation]},
	      IQ, gen_mod:get_module_proc(LServer, ?MODULE)),
	    ignore;
	error ->
	    Txt = <<"Failed to map delegated namespace to external component">>,
	    xmpp:make_error(IQ, xmpp:err_internal_server_error(Txt, Lang))
    end.

-spec process_iq_result(iq(), iq()) -> ok.
process_iq_result(#iq{from = From, to = To, id = ID, lang = Lang} = IQ,
		  #iq{type = result} = ResIQ) ->
    try
	CodecOpts = ejabberd_config:codec_options(To#jid.lserver),
	#delegation{forwarded = #forwarded{sub_els = [SubEl]}} =
	    xmpp:get_subtag(ResIQ, #delegation{}),
	case xmpp:decode(SubEl, ?NS_CLIENT, CodecOpts) of
	    #iq{from = To, to = From, type = Type, id = ID} = Reply
	      when Type == error; Type == result ->
		ejabberd_router:route(Reply)
	end
    catch _:_ ->
	    ?ERROR_MSG("got iq-result with invalid delegated "
		       "payload:~n~s", [xmpp:pp(ResIQ)]),
	    Txt = <<"External component failure">>,
	    Err = xmpp:err_internal_server_error(Txt, Lang),
	    ejabberd_router:route_error(IQ, Err)
    end;
process_iq_result(#iq{from = From, to = To}, #iq{type = error} = ResIQ) ->
    Err = xmpp:set_from_to(ResIQ, To, From),
    ejabberd_router:route(Err);
process_iq_result(#iq{lang = Lang} = IQ, timeout) ->
    Txt = <<"External component timeout">>,
    Err = xmpp:err_internal_server_error(Txt, Lang),
    ejabberd_router:route_error(IQ, Err).

-spec process_disco_info(state(), ejabberd_local | ejabberd_sm,
			 binary(), binary(), disco_info()) -> state().
process_disco_info(State, Type, Host, NS, Info) ->
    From = jid:make(State#state.server_host),
    To = jid:make(Host),
    case dict:find({NS, Type}, State#state.delegations) of
	error ->
	    Msg = #message{from = From, to = To,
			   sub_els = [#delegation{delegated = [#delegated{ns = NS}]}]},
	    Delegations = dict:store({NS, Type}, {Host, Info}, State#state.delegations),
	    gen_iq_handler:add_iq_handler(Type, State#state.server_host, NS,
					  ?MODULE, Type),
	    ejabberd_router:route(Msg),
	    ?INFO_MSG("Namespace '~s' is delegated to external component '~s'",
		      [NS, Host]),
	    State#state{delegations = Delegations};
	{ok, {AnotherHost, _}} ->
	    ?WARNING_MSG("Failed to delegate namespace '~s' to "
			 "external component '~s' because it's already "
			 "delegated to '~s'",
			 [NS, Host, AnotherHost]),
	    State
    end.

-spec send_disco_queries(binary(), binary(), binary()) -> ok.
send_disco_queries(LServer, Host, NS) ->
    From = jid:make(LServer),
    To = jid:make(Host),
    lists:foreach(
      fun({Type, Node}) ->
	      ejabberd_router:route_iq(
		#iq{type = get, from = From, to = To,
		    sub_els = [#disco_info{node = Node}]},
		{disco_info, Type, Host, NS},
		gen_mod:get_module_proc(LServer, ?MODULE))
      end, [{ejabberd_local, <<(?NS_DELEGATION)/binary, "::", NS/binary>>},
	    {ejabberd_sm, <<(?NS_DELEGATION)/binary, ":bare:", NS/binary>>}]).

-spec disco_features(disco_acc(), jid(), jid(), binary(), binary(),
		     ejabberd_local | ejabberd_sm) -> disco_acc().
disco_features(Acc, _From, To, <<"">>, _Lang, Type) ->
    Delegations = get_delegations(To#jid.lserver),
    Features = my_features(Type) ++
	lists:flatmap(
	  fun({{_, T}, {_, Info}}) when T == Type ->
		  Info#disco_info.features;
	     (_) ->
		  []
	  end, dict:to_list(Delegations)),
    case Acc of
	empty when Features /= [] -> {result, Features};
	{result, Fs} -> {result, Fs ++ Features};
	_ -> Acc
    end;
disco_features(Acc, _, _, _, _, _) ->
    Acc.

-spec disco_identity(disco_acc(), jid(), jid(), binary(), binary(),
		     ejabberd_local | ejabberd_sm) -> disco_acc().
disco_identity(Acc, _From, To, <<"">>, _Lang, Type) ->
    Delegations = get_delegations(To#jid.lserver),
    Identities = lists:flatmap(
		   fun({{_, T}, {_, Info}}) when T == Type ->
			   Info#disco_info.identities;
		      (_) ->
			   []
		   end, dict:to_list(Delegations)),
    case Acc of
	empty when Identities /= [] -> {result, Identities};
	{result, Ids} -> {result, Ids ++ Identities};
	Acc -> Acc
    end;
disco_identity(Acc, _From, _To, _Node, _Lang, _Type) ->
    Acc.

my_features(ejabberd_local) -> [?NS_DELEGATION];
my_features(ejabberd_sm) -> [].
