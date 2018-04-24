%%%----------------------------------------------------------------------
%%% File    : cyrsasl_digest.erl
%%% Author  : Alexey Shchepin <alexey@sevcom.net>
%%% Purpose : DIGEST-MD5 SASL mechanism
%%% Created : 11 Mar 2003 by Alexey Shchepin <alexey@sevcom.net>
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

-module(cyrsasl_digest).

-behaviour(ejabberd_config).

-author('alexey@sevcom.net').

-export([start/1, stop/0, mech_new/4, mech_step/2,
	 parse/1, format_error/1, opt_type/1]).

-include("ejabberd.hrl").
-include("logger.hrl").

-behaviour(cyrsasl).

-type get_password_fun() :: fun((binary()) -> {false, any()} |
                                              {binary(), atom()}).
-type check_password_fun() :: fun((binary(), binary(), binary(), binary(),
                                   fun((binary()) -> binary())) ->
                                           {boolean(), any()} |
                                           false).
-type error_reason() :: parser_failed | invalid_digest_uri |
			not_authorized | unexpected_response.
-export_type([error_reason/0]).

-record(state, {step = 1 :: 1 | 3 | 5,
                nonce = <<"">> :: binary(),
                username = <<"">> :: binary(),
                authzid = <<"">> :: binary(),
                get_password :: get_password_fun(),
                check_password :: check_password_fun(),
                auth_module :: atom(),
                host = <<"">> :: binary(),
                hostfqdn = [] :: [binary()]}).

start(_Opts) ->
    Fqdn = get_local_fqdn(),
    ?DEBUG("FQDN used to check DIGEST-MD5 SASL authentication: ~s",
	   [Fqdn]),
    cyrsasl:register_mechanism(<<"DIGEST-MD5">>, ?MODULE,
			       digest).

stop() -> ok.

-spec format_error(error_reason()) -> {atom(), binary()}.
format_error(parser_failed) ->
    {'bad-protocol', <<"Response decoding failed">>};
format_error(invalid_digest_uri) ->
    {'bad-protocol', <<"Invalid digest URI">>};
format_error(not_authorized) ->
    {'not-authorized', <<"Invalid username or password">>};
format_error(unexpected_response) ->
    {'bad-protocol', <<"Unexpected response">>}.

mech_new(Host, GetPassword, _CheckPassword,
	 CheckPasswordDigest) ->
    {ok,
     #state{step = 1, nonce = randoms:get_string(),
	    host = Host, hostfqdn = get_local_fqdn(),
	    get_password = GetPassword,
	    check_password = CheckPasswordDigest}}.

mech_step(#state{step = 1, nonce = Nonce} = State, _) ->
    {continue,
     <<"nonce=\"", Nonce/binary,
       "\",qop=\"auth\",charset=utf-8,algorithm=md5-sess">>,
     State#state{step = 3}};
mech_step(#state{step = 3, nonce = Nonce} = State,
	  ClientIn) ->
    case parse(ClientIn) of
	bad -> {error, parser_failed};
	KeyVals ->
	  DigestURI = proplists:get_value(<<"digest-uri">>, KeyVals, <<>>),
	  UserName = proplists:get_value(<<"username">>, KeyVals, <<>>),
	  case is_digesturi_valid(DigestURI, State#state.host,
				  State#state.hostfqdn)
	      of
	    false ->
		?DEBUG("User login not authorized because digest-uri "
		       "seems invalid: ~p (checking for Host "
		       "~p, FQDN ~p)",
		       [DigestURI, State#state.host, State#state.hostfqdn]),
		{error, invalid_digest_uri, UserName};
	    true ->
		AuthzId = proplists:get_value(<<"authzid">>, KeyVals, <<>>),
		case (State#state.get_password)(UserName) of
		  {false, _} -> {error, not_authorized, UserName};
		  {Passwd, AuthModule} ->
		      case (State#state.check_password)(UserName, UserName, <<"">>,
							proplists:get_value(<<"response">>, KeyVals, <<>>),
							fun (PW) ->
								response(KeyVals,
									 UserName,
									 PW,
									 Nonce,
									 AuthzId,
									 <<"AUTHENTICATE">>)
							end)
			  of
			{true, _} ->
			    RspAuth = response(KeyVals, UserName, Passwd, Nonce,
					       AuthzId, <<"">>),
			    {continue, <<"rspauth=", RspAuth/binary>>,
			     State#state{step = 5, auth_module = AuthModule,
					 username = UserName,
					 authzid = AuthzId}};
			false -> {error, not_authorized, UserName};
			{false, _} -> {error, not_authorized, UserName}
		      end
		end
	  end
    end;
mech_step(#state{step = 5, auth_module = AuthModule,
		 username = UserName, authzid = AuthzId},
	  <<"">>) ->
    {ok,
     [{username, UserName}, {authzid, case AuthzId of
        <<"">> -> UserName;
        _ -> AuthzId
      end
    },
      {auth_module, AuthModule}]};
mech_step(A, B) ->
    ?DEBUG("SASL DIGEST: A ~p B ~p", [A, B]),
    {error, unexpected_response}.

parse(S) -> parse1(binary_to_list(S), "", []).

parse1([$= | Cs], S, Ts) ->
    parse2(Cs, lists:reverse(S), "", Ts);
parse1([$, | Cs], [], Ts) -> parse1(Cs, [], Ts);
parse1([$\s | Cs], [], Ts) -> parse1(Cs, [], Ts);
parse1([C | Cs], S, Ts) -> parse1(Cs, [C | S], Ts);
parse1([], [], T) -> lists:reverse(T);
parse1([], _S, _T) -> bad.

parse2([$" | Cs], Key, Val, Ts) ->
    parse3(Cs, Key, Val, Ts);
parse2([C | Cs], Key, Val, Ts) ->
    parse4(Cs, Key, [C | Val], Ts);
parse2([], _, _, _) -> bad.

parse3([$" | Cs], Key, Val, Ts) ->
    parse4(Cs, Key, Val, Ts);
parse3([$\\, C | Cs], Key, Val, Ts) ->
    parse3(Cs, Key, [C | Val], Ts);
parse3([C | Cs], Key, Val, Ts) ->
    parse3(Cs, Key, [C | Val], Ts);
parse3([], _, _, _) -> bad.

parse4([$, | Cs], Key, Val, Ts) ->
    parse1(Cs, "", [{list_to_binary(Key), list_to_binary(lists:reverse(Val))} | Ts]);
parse4([$\s | Cs], Key, Val, Ts) ->
    parse4(Cs, Key, Val, Ts);
parse4([C | Cs], Key, Val, Ts) ->
    parse4(Cs, Key, [C | Val], Ts);
parse4([], Key, Val, Ts) ->
%% @doc Check if the digest-uri is valid.
%% RFC-2831 allows to provide the IP address in Host,
%% however ejabberd doesn't allow that.
%% If the service (for example jabber.example.org)
%% is provided by several hosts (being one of them server3.example.org),
%% then acceptable digest-uris would be:
%% xmpp/server3.example.org/jabber.example.org, xmpp/server3.example.org and
%% xmpp/jabber.example.org
%% The last version is not actually allowed by the RFC, but implemented by popular clients
    parse1([], "", [{list_to_binary(Key), list_to_binary(lists:reverse(Val))} | Ts]).

is_digesturi_valid(DigestURICase, JabberDomain,
		   JabberFQDN) ->
    DigestURI = stringprep:tolower(DigestURICase),
    case catch str:tokens(DigestURI, <<"/">>) of
	[<<"xmpp">>, Host] ->
	    IsHostFqdn = is_host_fqdn(Host, JabberFQDN),
	    (Host == JabberDomain) or IsHostFqdn;
	[<<"xmpp">>, Host, ServName] ->
	    IsHostFqdn = is_host_fqdn(Host, JabberFQDN),
	    (ServName == JabberDomain) and IsHostFqdn;
	_ ->
	    false
    end.

is_host_fqdn(_Host, []) ->
    false;
is_host_fqdn(Host, [Fqdn | _FqdnTail]) when Host == Fqdn ->
    true;
is_host_fqdn(Host, [Fqdn | FqdnTail]) when Host /= Fqdn ->
    is_host_fqdn(Host, FqdnTail).

get_local_fqdn() ->
    case ejabberd_config:get_option(fqdn) of
	undefined ->
	    {ok, Hostname} = inet:gethostname(),
	    {ok, {hostent, Fqdn, _, _, _, _}} = inet:gethostbyname(Hostname),
	    [list_to_binary(Fqdn)];
	Fqdn ->
	    Fqdn
    end.

hex(S) ->
    str:to_hexlist(S).

proplists_get_bin_value(Key, Pairs, Default) ->
    case proplists:get_value(Key, Pairs, Default) of
        L when is_list(L) ->
            list_to_binary(L);
        L2 ->
            L2
    end.

response(KeyVals, User, Passwd, Nonce, AuthzId,
	 A2Prefix) ->
    Realm = proplists_get_bin_value(<<"realm">>, KeyVals, <<>>),
    CNonce = proplists_get_bin_value(<<"cnonce">>, KeyVals, <<>>),
    DigestURI = proplists_get_bin_value(<<"digest-uri">>, KeyVals, <<>>),
    NC = proplists_get_bin_value(<<"nc">>, KeyVals, <<>>),
    QOP = proplists_get_bin_value(<<"qop">>, KeyVals, <<>>),
    MD5Hash = erlang:md5(<<User/binary, ":", Realm/binary, ":",
                           Passwd/binary>>),
    A1 = case AuthzId of
	   <<"">> ->
	       <<MD5Hash/binary, ":", Nonce/binary, ":", CNonce/binary>>;
	   _ ->
	       <<MD5Hash/binary, ":", Nonce/binary, ":", CNonce/binary, ":",
		 AuthzId/binary>>
	 end,
    A2 = case QOP of
	   <<"auth">> ->
	       <<A2Prefix/binary, ":", DigestURI/binary>>;
	   _ ->
	       <<A2Prefix/binary, ":", DigestURI/binary,
		 ":00000000000000000000000000000000">>
	 end,
    T = <<(hex((erlang:md5(A1))))/binary, ":", Nonce/binary,
	  ":", NC/binary, ":", CNonce/binary, ":", QOP/binary,
	  ":", (hex((erlang:md5(A2))))/binary>>,
    hex((erlang:md5(T))).

-spec opt_type(fqdn) -> fun((binary() | [binary()]) -> [binary()]);
	      (atom()) -> [atom()].
opt_type(fqdn) ->
    fun(FQDN) when is_binary(FQDN) ->
	    [FQDN];
       (FQDNs) when is_list(FQDNs) ->
	    [iolist_to_binary(FQDN) || FQDN <- FQDNs]
    end;
opt_type(_) -> [fqdn].
