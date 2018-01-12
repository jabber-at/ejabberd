%%%-------------------------------------------------------------------
%%% File    : mod_offline_mnesia.erl
%%% Author  : Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% Created : 15 Apr 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
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

-module(mod_offline_mnesia).

-behaviour(mod_offline).

-export([init/2, store_message/1, pop_messages/2, remove_expired_messages/1,
	 remove_old_messages/2, remove_user/2, read_message_headers/2,
	 read_message/3, remove_message/3, read_all_messages/2,
	 remove_all_messages/2, count_messages/2, import/1]).
-export([need_transform/1, transform/1]).

-include("xmpp.hrl").
-include("mod_offline.hrl").
-include("logger.hrl").

%%%===================================================================
%%% API
%%%===================================================================
init(_Host, _Opts) ->
    ejabberd_mnesia:create(?MODULE, offline_msg,
			   [{disc_only_copies, [node()]}, {type, bag},
			    {attributes, record_info(fields, offline_msg)}]).

store_message(#offline_msg{packet = Pkt} = OffMsg) ->
    El = xmpp:encode(Pkt),
    mnesia:dirty_write(OffMsg#offline_msg{packet = El}).

pop_messages(LUser, LServer) ->
    US = {LUser, LServer},
    F = fun () ->
		Rs = mnesia:wread({offline_msg, US}),
		mnesia:delete({offline_msg, US}),
		Rs
	end,
    case mnesia:transaction(F) of
	{atomic, L} ->
	    {ok, lists:keysort(#offline_msg.timestamp, L)};
	{aborted, Reason} ->
	    {error, Reason}
    end.

remove_expired_messages(_LServer) ->
    TimeStamp = p1_time_compat:timestamp(),
    F = fun () ->
		mnesia:write_lock_table(offline_msg),
		mnesia:foldl(fun (Rec, _Acc) ->
				     case Rec#offline_msg.expire of
					 never -> ok;
					 TS ->
					     if TS < TimeStamp ->
						     mnesia:delete_object(Rec);
						true -> ok
					     end
				     end
			     end,
			     ok, offline_msg)
	end,
    mnesia:transaction(F).

remove_old_messages(Days, _LServer) ->
    S = p1_time_compat:system_time(seconds) - 60 * 60 * 24 * Days,
    MegaSecs1 = S div 1000000,
    Secs1 = S rem 1000000,
    TimeStamp = {MegaSecs1, Secs1, 0},
    F = fun () ->
		mnesia:write_lock_table(offline_msg),
		mnesia:foldl(fun (#offline_msg{timestamp = TS} = Rec,
				  _Acc)
				     when TS < TimeStamp ->
				     mnesia:delete_object(Rec);
				 (_Rec, _Acc) -> ok
			     end,
			     ok, offline_msg)
	end,
    mnesia:transaction(F).

remove_user(LUser, LServer) ->
    US = {LUser, LServer},
    F = fun () -> mnesia:delete({offline_msg, US}) end,
    mnesia:transaction(F).

read_message_headers(LUser, LServer) ->
    Msgs = mnesia:dirty_read({offline_msg, {LUser, LServer}}),
    Hdrs = lists:map(
	     fun(#offline_msg{from = From, to = To, packet = Pkt,
			      timestamp = TS}) ->
		     Seq = now_to_integer(TS),
		     {Seq, From, To, TS, Pkt}
	     end, Msgs),
    lists:keysort(1, Hdrs).

read_message(LUser, LServer, I) ->
    US = {LUser, LServer},
    TS = integer_to_now(I),
    case mnesia:dirty_match_object(
	   offline_msg, #offline_msg{us = US, timestamp = TS, _ = '_'}) of
	[Msg|_] ->
	    {ok, Msg};
	_ ->
	    error
    end.

remove_message(LUser, LServer, I) ->
    US = {LUser, LServer},
    TS = integer_to_now(I),
    case mnesia:dirty_match_object(
	   offline_msg, #offline_msg{us = US, timestamp = TS, _ = '_'}) of
	[] ->
	    {error, notfound};
	Msgs ->
	    lists:foreach(
	      fun(Msg) ->
		      mnesia:dirty_delete_object(Msg)
	      end, Msgs)
    end.

read_all_messages(LUser, LServer) ->
    US = {LUser, LServer},
    lists:keysort(#offline_msg.timestamp,
		  mnesia:dirty_read({offline_msg, US})).

remove_all_messages(LUser, LServer) ->
    US = {LUser, LServer},
    F = fun () ->
		mnesia:write_lock_table(offline_msg),
		lists:foreach(fun (Msg) -> mnesia:delete_object(Msg) end,
			      mnesia:dirty_read({offline_msg, US}))
	end,
    mnesia:transaction(F).

count_messages(LUser, LServer) ->
    US = {LUser, LServer},
    F = fun () ->
		count_mnesia_records(US)
	end,
    case catch mnesia:async_dirty(F) of
	I when is_integer(I) -> I;
	_ -> 0
    end.

import(#offline_msg{} = Msg) ->
    mnesia:dirty_write(Msg).

need_transform(#offline_msg{us = {U, S}}) when is_list(U) orelse is_list(S) ->
    ?INFO_MSG("Mnesia table 'offline_msg' will be converted to binary", []),
    true;
need_transform(_) ->
    false.

transform(#offline_msg{us = {U, S}, from = From, to = To,
		       packet = El} = R) ->
    R#offline_msg{us = {iolist_to_binary(U), iolist_to_binary(S)},
		  from = jid_to_binary(From),
		  to = jid_to_binary(To),
		  packet = fxml:to_xmlel(El)}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
%% Return the number of records matching a given match expression.
%% This function is intended to be used inside a Mnesia transaction.
%% The count has been written to use the fewest possible memory by
%% getting the record by small increment and by using continuation.
-define(BATCHSIZE, 100).

count_mnesia_records(US) ->
    MatchExpression = #offline_msg{us = US,  _ = '_'},
    case mnesia:select(offline_msg, [{MatchExpression, [], [[]]}],
		       ?BATCHSIZE, read) of
	{Result, Cont} ->
	    Count = length(Result),
	    count_records_cont(Cont, Count);
	'$end_of_table' ->
	    0
    end.

count_records_cont(Cont, Count) ->
    case mnesia:select(Cont) of
	{Result, Cont} ->
	    NewCount = Count + length(Result),
	    count_records_cont(Cont, NewCount);
	'$end_of_table' ->
	    Count
    end.

jid_to_binary(#jid{user = U, server = S, resource = R,
                   luser = LU, lserver = LS, lresource = LR}) ->
    #jid{user = iolist_to_binary(U),
         server = iolist_to_binary(S),
         resource = iolist_to_binary(R),
         luser = iolist_to_binary(LU),
         lserver = iolist_to_binary(LS),
         lresource = iolist_to_binary(LR)}.

now_to_integer({MS, S, US}) ->
    (MS * 1000000 + S) * 1000000 + US.

integer_to_now(Int) ->
    Secs = Int div 1000000,
    USec = Int rem 1000000,
    MSec = Secs div 1000000,
    Sec = Secs rem 1000000,
    {MSec, Sec, USec}.
