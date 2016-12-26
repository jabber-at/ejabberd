%%%----------------------------------------------------------------------
%%% File    : ejabberd_s2s.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : S2S connections manager
%%% Created :  7 Dec 2002 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2016   ProcessOne
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

-module(ejabberd_s2s).

-protocol({xep, 220, '1.1'}).

-behaviour(ejabberd_config).

-author('alexey@process-one.net').

-behaviour(gen_server).

%% API
-export([start_link/0, route/3, have_connection/1,
	 make_key/2, get_connections_pids/1, try_register/1,
	 remove_connection/2, find_connection/2,
	 dirty_get_connections/0, allow_host/2,
	 incoming_s2s_number/0, outgoing_s2s_number/0,
	 stop_all_connections/0,
	 clean_temporarily_blocked_table/0,
	 list_temporarily_blocked_hosts/0,
	 external_host_overloaded/1, is_temporarly_blocked/1,
	 check_peer_certificate/3,
	 get_commands_spec/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
	 handle_info/2, terminate/2, code_change/3]).

-export([get_info_s2s_connections/1,
	 transform_options/1, opt_type/1]).

-include("ejabberd.hrl").
-include("logger.hrl").

-include("xmpp.hrl").

-include("ejabberd_commands.hrl").

-include_lib("public_key/include/public_key.hrl").

-define(PKIXEXPLICIT, 'OTP-PUB-KEY').

-define(PKIXIMPLICIT, 'OTP-PUB-KEY').

-include("XmppAddr.hrl").

-define(DEFAULT_MAX_S2S_CONNECTIONS_NUMBER, 1).

-define(DEFAULT_MAX_S2S_CONNECTIONS_NUMBER_PER_NODE, 1).

-define(S2S_OVERLOAD_BLOCK_PERIOD, 60).

%% once a server is temporarly blocked, it stay blocked for 60 seconds

-record(s2s, {fromto = {<<"">>, <<"">>} :: {binary(), binary()} | '_',
              pid = self()              :: pid() | '_' | '$1'}).

-record(state, {}).

-record(temporarily_blocked, {host = <<"">>     :: binary(),
                              timestamp         :: integer()}).

-type temporarily_blocked() :: #temporarily_blocked{}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [],
			  []).

-spec route(jid(), jid(), xmpp_element()) -> ok.

route(From, To, Packet) ->
    case catch do_route(From, To, Packet) of
      {'EXIT', Reason} ->
	  ?ERROR_MSG("~p~nwhen processing: ~p",
		     [Reason, {From, To, Packet}]);
      _ -> ok
    end.

clean_temporarily_blocked_table() ->
    mnesia:clear_table(temporarily_blocked).

-spec list_temporarily_blocked_hosts() -> [temporarily_blocked()].

list_temporarily_blocked_hosts() ->
    ets:tab2list(temporarily_blocked).

-spec external_host_overloaded(binary()) -> {aborted, any()} | {atomic, ok}.

external_host_overloaded(Host) ->
    ?INFO_MSG("Disabling connections from ~s for ~p "
	      "seconds",
	      [Host, ?S2S_OVERLOAD_BLOCK_PERIOD]),
    mnesia:transaction(fun () ->
                               Time = p1_time_compat:monotonic_time(),
			       mnesia:write(#temporarily_blocked{host = Host,
								 timestamp = Time})
		       end).

-spec is_temporarly_blocked(binary()) -> boolean().

is_temporarly_blocked(Host) ->
    case mnesia:dirty_read(temporarily_blocked, Host) of
      [] -> false;
      [#temporarily_blocked{timestamp = T} = Entry] ->
          Diff = p1_time_compat:monotonic_time() - T,
	  case p1_time_compat:convert_time_unit(Diff, native, micro_seconds) of
	    N when N > (?S2S_OVERLOAD_BLOCK_PERIOD) * 1000 * 1000 ->
		mnesia:dirty_delete_object(Entry), false;
	    _ -> true
	  end
    end.

-spec remove_connection({binary(), binary()},
                        pid()) -> {atomic, ok} | ok | {aborted, any()}.

remove_connection(FromTo, Pid) ->
    case catch mnesia:dirty_match_object(s2s,
					 #s2s{fromto = FromTo, pid = Pid})
	of
      [#s2s{pid = Pid}] ->
	  F = fun () ->
		      mnesia:delete_object(#s2s{fromto = FromTo, pid = Pid})
	      end,
	  mnesia:transaction(F);
      _ -> ok
    end.

-spec have_connection({binary(), binary()}) -> boolean().

have_connection(FromTo) ->
    case catch mnesia:dirty_read(s2s, FromTo) of
       [_] ->
            true;
        _ ->
            false
    end.

-spec get_connections_pids({binary(), binary()}) -> [pid()].

get_connections_pids(FromTo) ->
    case catch mnesia:dirty_read(s2s, FromTo) of
	L when is_list(L) ->
	    [Connection#s2s.pid || Connection <- L];
	_ ->
	    []
    end.

-spec try_register({binary(), binary()}) -> boolean().

try_register(FromTo) ->
    MaxS2SConnectionsNumber = max_s2s_connections_number(FromTo),
    MaxS2SConnectionsNumberPerNode =
	max_s2s_connections_number_per_node(FromTo),
    F = fun () ->
		L = mnesia:read({s2s, FromTo}),
		NeededConnections = needed_connections_number(L,
							      MaxS2SConnectionsNumber,
							      MaxS2SConnectionsNumberPerNode),
		if NeededConnections > 0 ->
		       mnesia:write(#s2s{fromto = FromTo, pid = self()}),
		       true;
		   true -> false
		end
	end,
    case mnesia:transaction(F) of
      {atomic, Res} -> Res;
      _ -> false
    end.

-spec dirty_get_connections() -> [{binary(), binary()}].

dirty_get_connections() ->
    mnesia:dirty_all_keys(s2s).

check_peer_certificate(SockMod, Sock, Peer) ->
    case SockMod:get_peer_certificate(Sock) of
      {ok, Cert} ->
	  case SockMod:get_verify_result(Sock) of
	    0 ->
		case ejabberd_idna:domain_utf8_to_ascii(Peer) of
		  false ->
		      {error, <<"Cannot decode remote server name">>};
		  AsciiPeer ->
		      case
			lists:any(fun(D) -> match_domain(AsciiPeer, D) end,
				  get_cert_domains(Cert)) of
			true ->
			    {ok, <<"Verification successful">>};
			false ->
			    {error, <<"Certificate host name mismatch">>}
		      end
		end;
	    VerifyRes ->
		{error, fast_tls:get_cert_verify_string(VerifyRes, Cert)}
	  end;
      {error, _Reason} ->
	    {error, <<"Cannot get peer certificate">>};
      error ->
	    {error, <<"Cannot get peer certificate">>}
    end.

-spec make_key({binary(), binary()}, binary()) -> binary().
make_key({From, To}, StreamID) ->
    Secret = ejabberd_config:get_option(shared_key, fun(V) -> V end),
    p1_sha:to_hexlist(
      crypto:hmac(sha256, p1_sha:to_hexlist(crypto:hash(sha256, Secret)),
		  [To, " ", From, " ", StreamID])).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    update_tables(),
    ejabberd_mnesia:create(?MODULE, s2s,
			[{ram_copies, [node()]},
			 {type, bag},
			 {attributes, record_info(fields, s2s)}]),
    mnesia:add_table_copy(s2s, node(), ram_copies),
    mnesia:subscribe(system),
    ejabberd_commands:register_commands(get_commands_spec()),
    ejabberd_mnesia:create(?MODULE, temporarily_blocked,
			[{ram_copies, [node()]},
			 {attributes, record_info(fields, temporarily_blocked)}]),
    {ok, #state{}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({mnesia_system_event, {mnesia_down, Node}}, State) ->
    clean_table_from_bad_node(Node),
    {noreply, State};
handle_info({route, From, To, Packet}, State) ->
    case catch do_route(From, To, Packet) of
      {'EXIT', Reason} ->
	  ?ERROR_MSG("~p~nwhen processing: ~p",
		     [Reason, {From, To, Packet}]);
      _ -> ok
    end,
    {noreply, State};
handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, _State) ->
    ejabberd_commands:unregister_commands(get_commands_spec()),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
-spec clean_table_from_bad_node(node()) -> any().
clean_table_from_bad_node(Node) ->
    F = fun() ->
		Es = mnesia:select(
		       s2s,
		       [{#s2s{pid = '$1', _ = '_'},
			 [{'==', {node, '$1'}, Node}],
			 ['$_']}]),
		lists:foreach(fun(E) ->
				      mnesia:delete_object(E)
			      end, Es)
	end,
    mnesia:async_dirty(F).

-spec do_route(jid(), jid(), stanza()) -> ok | false.
do_route(From, To, Packet) ->
    ?DEBUG("s2s manager~n\tfrom ~p~n\tto ~p~n\tpacket "
	   "~P~n",
	   [From, To, Packet, 8]),
    case find_connection(From, To) of
      {atomic, Pid} when is_pid(Pid) ->
	  ?DEBUG("sending to process ~p~n", [Pid]),
	  #jid{lserver = MyServer} = From,
	  ejabberd_hooks:run(s2s_send_packet, MyServer,
			     [From, To, Packet]),
	  send_element(Pid, xmpp:set_from_to(Packet, From, To)),
	  ok;
      {aborted, _Reason} ->
	  Lang = xmpp:get_lang(Packet),
	  Txt = <<"No s2s connection found">>,
	  Err = xmpp:err_service_unavailable(Txt, Lang),
	  ejabberd_router:route_error(To, From, Packet, Err),
	  false
    end.

-spec find_connection(jid(), jid()) -> {aborted, any()} | {atomic, pid()}.

find_connection(From, To) ->
    #jid{lserver = MyServer} = From,
    #jid{lserver = Server} = To,
    FromTo = {MyServer, Server},
    MaxS2SConnectionsNumber =
	max_s2s_connections_number(FromTo),
    MaxS2SConnectionsNumberPerNode =
	max_s2s_connections_number_per_node(FromTo),
    ?DEBUG("Finding connection for ~p~n", [FromTo]),
    case catch mnesia:dirty_read(s2s, FromTo) of
      {'EXIT', Reason} -> {aborted, Reason};
      [] ->
	  %% We try to establish all the connections if the host is not a
	  %% service and if the s2s host is not blacklisted or
	  %% is in whitelist:
	  case not is_service(From, To) andalso
		 allow_host(MyServer, Server)
	      of
	    true ->
		NeededConnections = needed_connections_number([],
							      MaxS2SConnectionsNumber,
							      MaxS2SConnectionsNumberPerNode),
		open_several_connections(NeededConnections, MyServer,
					 Server, From, FromTo,
					 MaxS2SConnectionsNumber,
					 MaxS2SConnectionsNumberPerNode);
	    false -> {aborted, error}
	  end;
      L when is_list(L) ->
	  NeededConnections = needed_connections_number(L,
							MaxS2SConnectionsNumber,
							MaxS2SConnectionsNumberPerNode),
	  if NeededConnections > 0 ->
		 %% We establish the missing connections for this pair.
		 open_several_connections(NeededConnections, MyServer,
					  Server, From, FromTo,
					  MaxS2SConnectionsNumber,
					  MaxS2SConnectionsNumberPerNode);
	     true ->
		 %% We choose a connexion from the pool of opened ones.
		 {atomic, choose_connection(From, L)}
	  end
    end.

-spec choose_connection(jid(), [#s2s{}]) -> pid().
choose_connection(From, Connections) ->
    choose_pid(From, [C#s2s.pid || C <- Connections]).

-spec choose_pid(jid(), [pid()]) -> pid().
choose_pid(From, Pids) ->
    Pids1 = case [P || P <- Pids, node(P) == node()] of
	      [] -> Pids;
	      Ps -> Ps
	    end,
    Pid =
	lists:nth(erlang:phash(jid:remove_resource(From),
			       length(Pids1)),
		  Pids1),
    ?DEBUG("Using ejabberd_s2s_out ~p~n", [Pid]),
    Pid.

open_several_connections(N, MyServer, Server, From,
			 FromTo, MaxS2SConnectionsNumber,
			 MaxS2SConnectionsNumberPerNode) ->
    ConnectionsResult = [new_connection(MyServer, Server,
					From, FromTo, MaxS2SConnectionsNumber,
					MaxS2SConnectionsNumberPerNode)
			 || _N <- lists:seq(1, N)],
    case [PID || {atomic, PID} <- ConnectionsResult] of
      [] -> hd(ConnectionsResult);
      PIDs -> {atomic, choose_pid(From, PIDs)}
    end.

new_connection(MyServer, Server, From, FromTo,
	       MaxS2SConnectionsNumber, MaxS2SConnectionsNumberPerNode) ->
    {ok, Pid} = ejabberd_s2s_out:start(
		  MyServer, Server, new),
    F = fun() ->
		L = mnesia:read({s2s, FromTo}),
		NeededConnections = needed_connections_number(L,
							      MaxS2SConnectionsNumber,
							      MaxS2SConnectionsNumberPerNode),
		if NeededConnections > 0 ->
		       mnesia:write(#s2s{fromto = FromTo, pid = Pid}),
		       ?INFO_MSG("New s2s connection started ~p", [Pid]),
		       Pid;
		   true -> choose_connection(From, L)
		end
	end,
    TRes = mnesia:transaction(F),
    case TRes of
      {atomic, Pid} -> ejabberd_s2s_out:start_connection(Pid);
      _ -> ejabberd_s2s_out:stop_connection(Pid)
    end,
    TRes.

-spec max_s2s_connections_number({binary(), binary()}) -> integer().
max_s2s_connections_number({From, To}) ->
    case acl:match_rule(From, max_s2s_connections, jid:make(To)) of
      Max when is_integer(Max) -> Max;
      _ -> ?DEFAULT_MAX_S2S_CONNECTIONS_NUMBER
    end.

-spec max_s2s_connections_number_per_node({binary(), binary()}) -> integer().
max_s2s_connections_number_per_node({From, To}) ->
    case acl:match_rule(From, max_s2s_connections_per_node, jid:make(To)) of
      Max when is_integer(Max) -> Max;
      _ -> ?DEFAULT_MAX_S2S_CONNECTIONS_NUMBER_PER_NODE
    end.

-spec needed_connections_number([#s2s{}], integer(), integer()) -> integer().
needed_connections_number(Ls, MaxS2SConnectionsNumber,
			  MaxS2SConnectionsNumberPerNode) ->
    LocalLs = [L || L <- Ls, node(L#s2s.pid) == node()],
    lists:min([MaxS2SConnectionsNumber - length(Ls),
	       MaxS2SConnectionsNumberPerNode - length(LocalLs)]).

%%--------------------------------------------------------------------
%% Function: is_service(From, To) -> true | false
%% Description: Return true if the destination must be considered as a
%% service.
%% --------------------------------------------------------------------
-spec is_service(jid(), jid()) -> boolean().
is_service(From, To) ->
    LFromDomain = From#jid.lserver,
    case ejabberd_config:get_option(
           {route_subdomains, LFromDomain},
           fun(s2s) -> s2s; (local) -> local end, local) of
      s2s -> % bypass RFC 3920 10.3
	  false;
      local ->
	  Hosts = (?MYHOSTS),
	  P = fun (ParentDomain) ->
		      lists:member(ParentDomain, Hosts)
	      end,
	  lists:any(P, parent_domains(To#jid.lserver))
    end.

parent_domains(Domain) ->
    lists:foldl(fun (Label, []) -> [Label];
		    (Label, [Head | Tail]) ->
			[<<Label/binary, ".", Head/binary>>, Head | Tail]
		end,
		[], lists:reverse(str:tokens(Domain, <<".">>))).

send_element(Pid, El) ->
    Pid ! {send_element, El}.

%%%----------------------------------------------------------------------
%%% ejabberd commands

get_commands_spec() ->
    [#ejabberd_commands{
        name = incoming_s2s_number,
			tags = [stats, s2s],
        desc = "Number of incoming s2s connections on the node",
                        policy = admin,
			module = ?MODULE, function = incoming_s2s_number,
			args = [], result = {s2s_incoming, integer}},
     #ejabberd_commands{
        name = outgoing_s2s_number,
			tags = [stats, s2s],
        desc = "Number of outgoing s2s connections on the node",
                        policy = admin,
			module = ?MODULE, function = outgoing_s2s_number,
			args = [], result = {s2s_outgoing, integer}},
     #ejabberd_commands{name = stop_all_connections,
			tags = [s2s],
			desc = "Stop all outgoing and incoming connections",
			policy = admin,
			module = ?MODULE, function = stop_all_connections,
			args = [], result = {res, rescode}}].

%% TODO Move those stats commands to ejabberd stats command ?
incoming_s2s_number() ->
    supervisor_count(ejabberd_s2s_in_sup).

outgoing_s2s_number() ->
    supervisor_count(ejabberd_s2s_out_sup).

supervisor_count(Supervisor) ->
    case catch supervisor:which_children(Supervisor) of
        {'EXIT', _} -> 0;
        Result ->
            length(Result)
    end.

stop_all_connections() ->
    lists:foreach(
      fun({_Id, Pid, _Type, _Module}) ->
	      exit(Pid, kill)
      end,
      supervisor:which_children(ejabberd_s2s_in_sup) ++
	  supervisor:which_children(ejabberd_s2s_out_sup)),
    mnesia:clear_table(s2s).

%%%----------------------------------------------------------------------
%%% Update Mnesia tables

update_tables() ->
    case catch mnesia:table_info(s2s, type) of
      bag -> ok;
      {'EXIT', _} -> ok;
      _ -> mnesia:delete_table(s2s)
    end,
    case catch mnesia:table_info(s2s, attributes) of
      [fromto, node, key] ->
	  mnesia:transform_table(s2s, ignore, [fromto, pid]),
	  mnesia:clear_table(s2s);
      [fromto, pid, key] ->
	  mnesia:transform_table(s2s, ignore, [fromto, pid]),
	  mnesia:clear_table(s2s);
      [fromto, pid] -> ok;
      {'EXIT', _} -> ok
    end,
    case lists:member(local_s2s, mnesia:system_info(tables)) of
	true -> mnesia:delete_table(local_s2s);
	false -> ok
    end.

%% Check if host is in blacklist or white list
allow_host(MyServer, S2SHost) ->
    allow_host2(MyServer, S2SHost) andalso
      not is_temporarly_blocked(S2SHost).

allow_host2(MyServer, S2SHost) ->
    Hosts = (?MYHOSTS),
    case lists:dropwhile(fun (ParentDomain) ->
				 not lists:member(ParentDomain, Hosts)
			 end,
			 parent_domains(MyServer))
	of
      [MyHost | _] -> allow_host1(MyHost, S2SHost);
      [] -> allow_host1(MyServer, S2SHost)
    end.

allow_host1(MyHost, S2SHost) ->
    Rule = ejabberd_config:get_option(
             s2s_access,
             fun(A) -> A end,
             all),
    JID = jid:make(S2SHost),
    case acl:match_rule(MyHost, Rule, JID) of
        deny -> false;
        allow ->
            case ejabberd_hooks:run_fold(s2s_allow_host, MyHost,
                                         allow, [MyHost, S2SHost]) of
                deny -> false;
                allow -> true;
                _ -> true
            end
    end.

transform_options(Opts) ->
    lists:foldl(fun transform_options/2, [], Opts).

transform_options({{s2s_host, Host}, Action}, Opts) ->
    ?WARNING_MSG("Option 's2s_host' is deprecated. "
                 "The option is still supported but it is better to "
                 "fix your config: use access rules instead.", []),
    ACLName = jlib:binary_to_atom(
                iolist_to_binary(["s2s_access_", Host])),
    [{acl, ACLName, {server, Host}},
     {access, s2s, [{Action, ACLName}]},
     {s2s_access, s2s} |
     Opts];
transform_options({s2s_default_policy, Action}, Opts) ->
    ?WARNING_MSG("Option 's2s_default_policy' is deprecated. "
                 "The option is still supported but it is better to "
                 "fix your config: "
                 "use 's2s_access' with an access rule.", []),
    [{access, s2s, [{Action, all}]},
     {s2s_access, s2s} |
     Opts];
transform_options(Opt, Opts) ->
    [Opt|Opts].

%% Get information about S2S connections of the specified type.
%% @spec (Type) -> [Info]
%% where Type = in | out
%%       Info = [{InfoName::atom(), InfoValue::any()}]
get_info_s2s_connections(Type) ->
    ChildType = case Type of
		  in -> ejabberd_s2s_in_sup;
		  out -> ejabberd_s2s_out_sup
		end,
    Connections = supervisor:which_children(ChildType),
    get_s2s_info(Connections, Type).

get_s2s_info(Connections, Type) ->
    complete_s2s_info(Connections, Type, []).

complete_s2s_info([], _, Result) -> Result;
complete_s2s_info([Connection | T], Type, Result) ->
    {_, PID, _, _} = Connection,
    State = get_s2s_state(PID),
    complete_s2s_info(T, Type, [State | Result]).

-spec get_s2s_state(pid()) -> [{status, open | closed | error} | {s2s_pid, pid()}].

get_s2s_state(S2sPid) ->
    Infos = case gen_fsm:sync_send_all_state_event(S2sPid,
						   get_state_infos)
		of
	      {state_infos, Is} -> [{status, open} | Is];
	      {noproc, _} -> [{status, closed}]; %% Connection closed
	      {badrpc, _} -> [{status, error}]
	    end,
    [{s2s_pid, S2sPid} | Infos].

get_cert_domains(Cert) ->
    TBSCert = Cert#'Certificate'.tbsCertificate,
    Subject = case TBSCert#'TBSCertificate'.subject of
		  {rdnSequence, Subj} -> lists:flatten(Subj);
		  _ -> []
	      end,
    Extensions = case TBSCert#'TBSCertificate'.extensions of
		     Exts when is_list(Exts) -> Exts;
		     _ -> []
		 end,
    lists:flatmap(fun (#'AttributeTypeAndValue'{type =
						    ?'id-at-commonName',
						value = Val}) ->
			  case 'OTP-PUB-KEY':decode('X520CommonName', Val) of
			    {ok, {_, D1}} ->
				D = if is_binary(D1) -> D1;
				       is_list(D1) -> list_to_binary(D1);
				       true -> error
				    end,
				if D /= error ->
				       case jid:from_string(D) of
					 #jid{luser = <<"">>, lserver = LD,
					      lresource = <<"">>} ->
					     [LD];
					 _ -> []
				       end;
				   true -> []
				end;
			    _ -> []
			  end;
		      (_) -> []
		  end,
		  Subject)
      ++
      lists:flatmap(fun (#'Extension'{extnID =
					  ?'id-ce-subjectAltName',
				      extnValue = Val}) ->
			    BVal = if is_list(Val) -> list_to_binary(Val);
				      true -> Val
				   end,
			    case 'OTP-PUB-KEY':decode('SubjectAltName', BVal)
				of
			      {ok, SANs} ->
				  lists:flatmap(fun ({otherName,
						      #'AnotherName'{'type-id' =
									 ?'id-on-xmppAddr',
								     value =
									 XmppAddr}}) ->
							case
							  'XmppAddr':decode('XmppAddr',
									    XmppAddr)
							    of
							  {ok, D}
							      when
								is_binary(D) ->
							      case
								jid:from_string((D))
								  of
								#jid{luser =
									 <<"">>,
								     lserver =
									 LD,
								     lresource =
									 <<"">>} ->
								    case
								      ejabberd_idna:domain_utf8_to_ascii(LD)
									of
								      false ->
									  [];
								      PCLD ->
									  [PCLD]
								    end;
								_ -> []
							      end;
							  _ -> []
							end;
						    ({dNSName, D})
							when is_list(D) ->
							case
							  jid:from_string(list_to_binary(D))
							    of
							  #jid{luser = <<"">>,
							       lserver = LD,
							       lresource =
								   <<"">>} ->
							      [LD];
							  _ -> []
							end;
						    (_) -> []
						end,
						SANs);
			      _ -> []
			    end;
			(_) -> []
		    end,
		    Extensions).

match_domain(Domain, Domain) -> true;
match_domain(Domain, Pattern) ->
    DLabels = str:tokens(Domain, <<".">>),
    PLabels = str:tokens(Pattern, <<".">>),
    match_labels(DLabels, PLabels).

match_labels([], []) -> true;
match_labels([], [_ | _]) -> false;
match_labels([_ | _], []) -> false;
match_labels([DL | DLabels], [PL | PLabels]) ->
    case lists:all(fun (C) ->
			   $a =< C andalso C =< $z orelse
			     $0 =< C andalso C =< $9 orelse
			       C == $- orelse C == $*
		   end,
		   binary_to_list(PL))
	of
      true ->
	  Regexp = ejabberd_regexp:sh_to_awk(PL),
	  case ejabberd_regexp:run(DL, Regexp) of
	    match -> match_labels(DLabels, PLabels);
	    nomatch -> false
	  end;
      false -> false
    end.

opt_type(route_subdomains) ->
    fun (s2s) -> s2s;
	(local) -> local
    end;
opt_type(s2s_access) ->
    fun acl:access_rules_validator/1;
opt_type(_) -> [route_subdomains, s2s_access].
