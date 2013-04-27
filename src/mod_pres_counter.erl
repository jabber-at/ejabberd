%%%----------------------------------------------------------------------
%%% File    : mod_pres_counter.erl
%%% Author  : Ahmed Omar
%%% Purpose : Presence subscription flood prevention
%%% Created : 23 Sep 2010 by Ahmed Omar
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2013   ProcessOne
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
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%----------------------------------------------------------------------

-module(mod_pres_counter).

-behavior(gen_mod).

-export([start/2,
	 stop/1,
	 check_packet/6]).

-include("ejabberd.hrl").
-include("jlib.hrl").

-record(pres_counter, {dir, start, count, logged = false}).

start(Host, _Opts) ->
    ejabberd_hooks:add(privacy_check_packet, Host,
		       ?MODULE, check_packet, 25),
    ok.

stop(Host) ->
    ejabberd_hooks:delete(privacy_check_packet, Host,
			  ?MODULE, check_packet, 25),
    ok.

check_packet(_, _User, Server,
	     _PrivacyList,
	     {From, To, {xmlelement, Name, Attrs, _}},
	     Dir) ->
    case Name of
	"presence" ->
	    IsSubscription =
		case xml:get_attr_s("type", Attrs) of
		    "subscribe" -> true;
		    "subscribed" -> true;
		    "unsubscribe" -> true;
		    "unsubscribed" -> true;
		    _ -> false
		end,
	    if
		IsSubscription ->
		    JID = case Dir of
			      in -> To;
			      out -> From
			  end,
		    update(Server, JID, Dir);
		true ->
		    allow
	    end;
	_ ->
	    allow
    end.

update(Server, JID, Dir) ->
    %% get options
    StormCount = gen_mod:get_module_opt(Server, ?MODULE, count, 5),
    TimeInterval = gen_mod:get_module_opt(Server, ?MODULE, interval, 60),
    {MegaSecs, Secs, _MicroSecs} = now(),
    TimeStamp = MegaSecs * 1000000 + Secs,
    case read(Dir) of
	undefined ->
	    write(Dir, #pres_counter{dir = Dir,
				     start = TimeStamp,
				     count = 1}),
	    allow;
	#pres_counter{start = TimeStart, count = Count, logged = Logged} = R ->
	    %% record for this key exists, check if we're
	    %% within TimeInterval seconds, and whether the StormCount is
	    %% high enough.  or else just increment the count.
	    if
		TimeStamp - TimeStart > TimeInterval ->
		    write(Dir, R#pres_counter{
				 start = TimeStamp,
				 count = 1}),
		    allow;
		(Count =:= StormCount) and Logged ->
		    {stop, deny};
		Count =:= StormCount ->
		    write(Dir, R#pres_counter{logged = true}),
		    case Dir of
			in ->
			    ?WARNING_MSG(
			       "User ~s is being flooded, "
			       "ignoring received presence subscriptions",
			       [jlib:jid_to_string(JID)]);
			out ->
			    IP = ejabberd_sm:get_user_ip(
				   JID#jid.luser,
				   JID#jid.lserver,
				   JID#jid.lresource),
			    ?WARNING_MSG(
			       "Flooder detected: ~s, on IP: ~s "
			       "ignoring sent presence subscriptions~n",
			       [jlib:jid_to_string(JID),
				jlib:ip_to_list(IP)])
		    end,
		    {stop, deny};
		true ->
		    write(Dir, R#pres_counter{
				 start = TimeStamp,
				 count = Count + 1}),
		    allow
	    end
    end.

read(K)->
    get({pres_counter, K}).

write(K, V)->
    put({pres_counter, K}, V).
