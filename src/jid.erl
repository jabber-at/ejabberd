%%%-------------------------------------------------------------------
%%% @author Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% @doc
%%%   JID processing library
%%% @end
%%% Created : 24 Nov 2015 by Evgeny Khramtsov <ekhramtsov@process-one.net>
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
%%%-------------------------------------------------------------------
-module(jid).

%% API
-export([start/0,
	 make/1,
	 make/3,
	 split/1,
	 from_string/1,
	 to_string/1,
	 is_nodename/1,
	 nodeprep/1,
	 nameprep/1,
	 resourceprep/1,
	 tolower/1,
	 remove_resource/1,
	 replace_resource/2]).

-include("jlib.hrl").

-export_type([jid/0]).

%%%===================================================================
%%% API
%%%===================================================================
-spec start() -> ok.

start() ->
    {ok, Owner} = ets_owner(),
    SplitPattern = binary:compile_pattern([<<"@">>, <<"/">>]),
    %% Table is public to allow ETS insert to fix / update the table even if table already exist
    %% with another owner.
    catch ets:new(jlib, [named_table, public, set, {keypos, 1}, {heir, Owner, undefined}]),
    ets:insert(jlib, {string_to_jid_pattern, SplitPattern}),
    ok.

ets_owner() ->
    case whereis(jlib_ets) of
        undefined ->
            Pid = spawn(fun() -> ets_keepalive() end),
            case catch register(jlib_ets, Pid) of
                true ->
                    {ok, Pid};
                Error -> Error
            end;
        Pid ->
            {ok,Pid}
    end.

%% Process used to keep jlib ETS table alive in case the original owner dies.
%% The table need to be public, otherwise subsequent inserts would fail.
ets_keepalive() ->
    receive
        _ ->
            ets_keepalive()
    end.

-spec make(binary(), binary(), binary()) -> jid() | error.

make(User, Server, Resource) ->
    case nodeprep(User) of
      error -> error;
      LUser ->
	  case nameprep(Server) of
	    error -> error;
	    LServer ->
		case resourceprep(Resource) of
		  error -> error;
		  LResource ->
		      #jid{user = User, server = Server, resource = Resource,
			   luser = LUser, lserver = LServer,
			   lresource = LResource}
		end
	  end
    end.

-spec make({binary(), binary(), binary()}) -> jid() | error.

make({User, Server, Resource}) ->
    make(User, Server, Resource).

%% This is the reverse of make_jid/1
-spec split(jid()) -> {binary(), binary(), binary()} | error.

split(#jid{user = U, server = S, resource = R}) ->
    {U, S, R};
split(_) ->
    error.

-spec from_string(binary() | string()) -> jid() | error.
from_string(S) when is_list(S) ->
    %% We do not accept list because we want to enforce good practice of
    %% using binaries for string. However, we do not let it crash to avoid
    %% losing associated ets table.
    {error, need_jid_as_binary};
from_string(S) when is_binary(S) ->
    SplitPattern = ets:lookup_element(jlib, string_to_jid_pattern, 2),
    Size = size(S),
    End = Size-1,
    case binary:match(S, SplitPattern) of
        {0, _} ->
            error;
        {End, _} ->
            error;
        {Pos1, _} ->
            case binary:at(S, Pos1) of
                $/ ->
                    make(<<>>,
			 binary:part(S, 0, Pos1),
			 binary:part(S, Pos1+1, Size-Pos1-1));
                _ ->
                    Pos1N = Pos1+1,
                    case binary:match(S, SplitPattern, [{scope, {Pos1+1, Size-Pos1-1}}]) of
                        {End, _} ->
                            error;
                        {Pos1N, _} ->
                            error;
                        {Pos2, _} ->
                            case binary:at(S, Pos2) of
                                $/ ->
                                    make(binary:part(S, 0, Pos1),
					 binary:part(S, Pos1+1, Pos2-Pos1-1),
					 binary:part(S, Pos2+1, Size-Pos2-1));
                                _ -> error
                            end;
                        _ ->
                            make(binary:part(S, 0, Pos1),
				 binary:part(S, Pos1+1, Size-Pos1-1),
				 <<>>)
                    end
            end;
        _ ->
            make(<<>>, S, <<>>)
    end.

-spec to_string(jid() | ljid()) -> binary().

to_string(#jid{user = User, server = Server,
	       resource = Resource}) ->
    to_string({User, Server, Resource});
to_string({N, S, R}) ->
    Node = iolist_to_binary(N),
    Server = iolist_to_binary(S),
    Resource = iolist_to_binary(R),
    S1 = case Node of
	   <<"">> -> <<"">>;
	   _ -> <<Node/binary, "@">>
	 end,
    S2 = <<S1/binary, Server/binary>>,
    S3 = case Resource of
	   <<"">> -> S2;
	   _ -> <<S2/binary, "/", Resource/binary>>
	 end,
    S3.

-spec is_nodename(binary()) -> boolean().

is_nodename(Node) ->
    N = nodeprep(Node),
    (N /= error) and (N /= <<>>).

-define(LOWER(Char),
	if Char >= $A, Char =< $Z -> Char + 32;
	   true -> Char
	end).

-spec nodeprep(binary()) -> binary() | error.

nodeprep("") -> <<>>;
nodeprep(S) when byte_size(S) < 1024 ->
    R = stringprep:nodeprep(S),
    if byte_size(R) < 1024 -> R;
       true -> error
    end;
nodeprep(_) -> error.

-spec nameprep(binary()) -> binary() | error.

nameprep(S) when byte_size(S) < 1024 ->
    R = stringprep:nameprep(S),
    if byte_size(R) < 1024 -> R;
       true -> error
    end;
nameprep(_) -> error.

-spec resourceprep(binary()) -> binary() | error.

resourceprep(S) when byte_size(S) < 1024 ->
    R = stringprep:resourceprep(S),
    if byte_size(R) < 1024 -> R;
       true -> error
    end;
resourceprep(_) -> error.

-spec tolower(jid() | ljid()) -> error | ljid().

tolower(#jid{luser = U, lserver = S,
	     lresource = R}) ->
    {U, S, R};
tolower({U, S, R}) ->
    case nodeprep(U) of
      error -> error;
      LUser ->
	  case nameprep(S) of
	    error -> error;
	    LServer ->
		case resourceprep(R) of
		  error -> error;
		  LResource -> {LUser, LServer, LResource}
		end
	  end
    end.

-spec remove_resource(jid()) -> jid();
		     (ljid()) -> ljid().

remove_resource(#jid{} = JID) ->
    JID#jid{resource = <<"">>, lresource = <<"">>};
remove_resource({U, S, _R}) -> {U, S, <<"">>}.

-spec replace_resource(jid(), binary()) -> error | jid().

replace_resource(JID, Resource) ->
    case resourceprep(Resource) of
      error -> error;
      LResource ->
	  JID#jid{resource = Resource, lresource = LResource}
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================
