%%%----------------------------------------------------------------------
%%% File    : ejabberd_app.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : ejabberd's application callback module
%%% Created : 31 Jan 2003 by Alexey Shchepin <alexey@process-one.net>
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

-module(ejabberd_app).

-behaviour(ejabberd_config).
-author('alexey@process-one.net').

-behaviour(application).

-export([start/2, prep_stop/1, stop/1, opt_type/1]).

-include("ejabberd.hrl").
-include("logger.hrl").

%%%
%%% Application API
%%%

start(normal, _Args) ->
    {T1, _} = statistics(wall_clock),
    ejabberd_logger:start(),
    write_pid_file(),
    start_apps(),
    start_elixir_application(),
    ejabberd:check_app(ejabberd),
    db_init(),
    setup_if_elixir_conf_used(),
    ejabberd_config:start(),
    set_settings_from_config(),
    file_queue_init(),
    maybe_add_nameservers(),
    connect_nodes(),
    case ejabberd_sup:start_link() of
	{ok, SupPid} ->
	    register_elixir_config_hooks(),
	    {T2, _} = statistics(wall_clock),
	    ?INFO_MSG("ejabberd ~s is started in the node ~p in ~.2fs",
		      [?VERSION, node(), (T2-T1)/1000]),
	    {ok, SupPid};
	Err ->
	    Err
    end;
start(_, _) ->
    {error, badarg}.

%% Prepare the application for termination.
%% This function is called when an application is about to be stopped,
%% before shutting down the processes of the application.
prep_stop(State) ->
    ejabberd_listener:stop_listeners(),
    ejabberd_sm:stop(),
    gen_mod:stop_modules(),
    State.

%% All the processes were killed when this function is called
stop(_State) ->
    ?INFO_MSG("ejabberd ~s is stopped in the node ~p", [?VERSION, node()]),
    delete_pid_file(),
    %%ejabberd_debug:stop(),
    ok.


%%%
%%% Internal functions
%%%

db_init() ->
    ejabberd_config:env_binary_to_list(mnesia, dir),
    MyNode = node(),
    DbNodes = mnesia:system_info(db_nodes),
    case lists:member(MyNode, DbNodes) of
	true ->
	    ok;
	false ->
	    ?CRITICAL_MSG("Node name mismatch: I'm [~s], "
			  "the database is owned by ~p", [MyNode, DbNodes]),
	    ?CRITICAL_MSG("Either set ERLANG_NODE in ejabberdctl.cfg "
			  "or change node name in Mnesia", []),
	    erlang:error(node_name_mismatch)
    end,
    case mnesia:system_info(extra_db_nodes) of
	[] ->
	    mnesia:create_schema([node()]);
	_ ->
	    ok
    end,
    ejabberd:start_app(mnesia, permanent),
    mnesia:wait_for_tables(mnesia:system_info(local_tables), infinity).

connect_nodes() ->
    Nodes = ejabberd_config:get_option(
              cluster_nodes,
              fun(Ns) ->
                      true = lists:all(fun is_atom/1, Ns),
                      Ns
              end, []),
    lists:foreach(fun(Node) ->
                          net_kernel:connect_node(Node)
                  end, Nodes).

%% If ejabberd is running on some Windows machine, get nameservers and add to Erlang
maybe_add_nameservers() ->
    case os:type() of
	{win32, _} -> add_windows_nameservers();
	_ -> ok
    end.

add_windows_nameservers() ->
    IPTs = win32_dns:get_nameservers(),
    ?INFO_MSG("Adding machine's DNS IPs to Erlang system:~n~p", [IPTs]),
    lists:foreach(fun(IPT) -> inet_db:add_ns(IPT) end, IPTs).

%%%
%%% PID file
%%%

write_pid_file() ->
    case ejabberd:get_pid_file() of
	false ->
	    ok;
	PidFilename ->
	    write_pid_file(os:getpid(), PidFilename)
    end.

write_pid_file(Pid, PidFilename) ->
    case file:open(PidFilename, [write]) of
	{ok, Fd} ->
	    io:format(Fd, "~s~n", [Pid]),
	    file:close(Fd);
	{error, Reason} ->
	    ?ERROR_MSG("Cannot write PID file ~s~nReason: ~p", [PidFilename, Reason]),
	    throw({cannot_write_pid_file, PidFilename, Reason})
    end.

delete_pid_file() ->
    case ejabberd:get_pid_file() of
	false ->
	    ok;
	PidFilename ->
	    file:delete(PidFilename)
    end.

set_settings_from_config() ->
    Ticktime = ejabberd_config:get_option(
                 net_ticktime,
                 opt_type(net_ticktime),
                 60),
    net_kernel:set_net_ticktime(Ticktime).

file_queue_init() ->
    QueueDir = case ejabberd_config:queue_dir() of
		   undefined ->
		       MnesiaDir = mnesia:system_info(directory),
		       filename:join(MnesiaDir, "queue");
		   Path ->
		       Path
	       end,
    p1_queue:start(QueueDir).

start_apps() ->
    crypto:start(),
    ejabberd:start_app(sasl),
    ejabberd:start_app(ssl),
    ejabberd:start_app(fast_yaml),
    ejabberd:start_app(fast_tls),
    ejabberd:start_app(xmpp),
    ejabberd:start_app(cache_tab).

opt_type(net_ticktime) ->
    fun (P) when is_integer(P), P > 0 -> P end;
opt_type(cluster_nodes) ->
    fun (Ns) -> true = lists:all(fun is_atom/1, Ns), Ns end;
opt_type(_) -> [cluster_nodes, net_ticktime].

setup_if_elixir_conf_used() ->
  case ejabberd_config:is_using_elixir_config() of
    true -> 'Elixir.Ejabberd.Config.Store':start_link();
    false -> ok
  end.

register_elixir_config_hooks() ->
  case ejabberd_config:is_using_elixir_config() of
    true -> 'Elixir.Ejabberd.Config':start_hooks();
    false -> ok
  end.

start_elixir_application() ->
    case ejabberd_config:is_elixir_enabled() of
	true ->
	    case application:ensure_started(elixir) of
		ok -> ok;
		{error, _Msg} -> ?ERROR_MSG("Elixir application not started.", [])
	    end;
	_ ->
	    ok
    end.
