%%%----------------------------------------------------------------------
%%% File    : mod_pres_counter.erl
%%% Author  : Ahmed Omar
%%% Purpose : Presence subscription flood prevention
%%% Created : 23 Sep 2010 by Ahmed Omar
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2017   ProcessOne
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

-module(mod_pres_counter).

-behavior(gen_mod).

-export([start/2, stop/1, reload/3, check_packet/4,
	 mod_opt_type/1, depends/2]).

-include("ejabberd.hrl").
-include("logger.hrl").

-include("xmpp.hrl").

-record(pres_counter,
	{dir, start, count, logged = false}).

start(Host, _Opts) ->
    ejabberd_hooks:add(privacy_check_packet, Host, ?MODULE,
		       check_packet, 25),
    ok.

stop(Host) ->
    ejabberd_hooks:delete(privacy_check_packet, Host,
			  ?MODULE, check_packet, 25),
    ok.

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [].

-spec check_packet(allow | deny, ejabberd_c2s:state() | jid(),
		   stanza(), in | out) -> allow | deny.
check_packet(Acc, #{jid := JID}, Packet, Dir) ->
    check_packet(Acc, JID, Packet, Dir);
check_packet(_, #jid{lserver = LServer},
	     #presence{from = From, to = To, type = Type}, Dir) ->
    IsSubscription = case Type of
			 subscribe -> true;
			 subscribed -> true;
			 unsubscribe -> true;
			 unsubscribed -> true;
			 _ -> false
		     end,
    if IsSubscription ->
	    JID = case Dir of
		      in -> To;
		      out -> From
		  end,
	    update(LServer, JID, Dir);
       true -> allow
    end;
check_packet(Acc, _, _, _) ->
    Acc.

update(Server, JID, Dir) ->
    StormCount = gen_mod:get_module_opt(Server, ?MODULE, count, 5),
    TimeInterval = gen_mod:get_module_opt(Server, ?MODULE, interval, 60),
    TimeStamp = p1_time_compat:system_time(seconds),
    case read(Dir) of
      undefined ->
	  write(Dir,
		#pres_counter{dir = Dir, start = TimeStamp, count = 1}),
	  allow;
      #pres_counter{start = TimeStart, count = Count,
		    logged = Logged} =
	  R ->
	  if TimeStamp - TimeStart > TimeInterval ->
		 write(Dir,
		       R#pres_counter{start = TimeStamp, count = 1}),
		 allow;
	     (Count =:= StormCount) and Logged -> {stop, deny};
	     Count =:= StormCount ->
		 write(Dir, R#pres_counter{logged = true}),
		 case Dir of
		   in ->
		       ?WARNING_MSG("User ~s is being flooded, ignoring received "
				    "presence subscriptions",
				    [jid:encode(JID)]);
		   out ->
		       IP = ejabberd_sm:get_user_ip(JID#jid.luser,
						    JID#jid.lserver,
						    JID#jid.lresource),
		       ?WARNING_MSG("Flooder detected: ~s, on IP: ~s ignoring "
				    "sent presence subscriptions~n",
				    [jid:encode(JID),
				     misc:ip_to_list(IP)])
		 end,
		 {stop, deny};
	     true ->
		 write(Dir,
		       R#pres_counter{start = TimeStamp, count = Count + 1}),
		 allow
	  end
    end.

read(K) -> get({pres_counter, K}).

write(K, V) -> put({pres_counter, K}, V).

mod_opt_type(count) ->
    fun (I) when is_integer(I), I > 0 -> I end;
mod_opt_type(interval) ->
    fun (I) when is_integer(I), I > 0 -> I end;
mod_opt_type(_) -> [count, interval].
