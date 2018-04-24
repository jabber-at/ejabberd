%%%----------------------------------------------------------------------
%%% File    : ejabberd_sql.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Serve SQL connection
%%% Created :  8 Dec 2004 by Alexey Shchepin <alexey@process-one.net>
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

-module(ejabberd_sql).

-behaviour(ejabberd_config).

-author('alexey@process-one.net').

-behaviour(p1_fsm).

%% External exports
-export([start/1, start_link/2,
	 sql_query/2,
	 sql_query_t/1,
	 sql_transaction/2,
	 sql_bloc/2,
         abort/1,
         restart/1,
         use_new_schema/0,
         sql_query_to_iolist/1,
	 escape/1,
         standard_escape/1,
	 escape_like/1,
	 escape_like_arg/1,
	 escape_like_arg_circumflex/1,
	 to_bool/1,
	 sqlite_db/1,
	 sqlite_file/1,
	 encode_term/1,
	 decode_term/1,
	 odbc_config/0,
	 freetds_config/0,
	 odbcinst_config/0,
	 init_mssql/1,
	 keep_alive/2]).

%% gen_fsm callbacks
-export([init/1, handle_event/3, handle_sync_event/4,
	 handle_info/3, terminate/3, print_state/1,
	 code_change/4]).

-export([connecting/2, connecting/3,
	 session_established/2, session_established/3,
	 opt_type/1]).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("ejabberd_sql_pt.hrl").

-record(state,
	{db_ref = self()                     :: pid(),
	 db_type = odbc                      :: pgsql | mysql | sqlite | odbc | mssql,
	 db_version = undefined              :: undefined | non_neg_integer(),
	 start_interval = 0                  :: non_neg_integer(),
	 host = <<"">>                       :: binary(),
	 pending_requests                    :: p1_queue:queue()}).

-define(STATE_KEY, ejabberd_sql_state).

-define(NESTING_KEY, ejabberd_sql_nesting_level).

-define(TOP_LEVEL_TXN, 0).

-define(PGSQL_PORT, 5432).

-define(MYSQL_PORT, 3306).

-define(MSSQL_PORT, 1433).

-define(MAX_TRANSACTION_RESTARTS, 10).

-define(KEEPALIVE_QUERY, [<<"SELECT 1;">>]).

-define(PREPARE_KEY, ejabberd_sql_prepare).

-ifdef(NEW_SQL_SCHEMA).
-define(USE_NEW_SCHEMA_DEFAULT, true).
-else.
-define(USE_NEW_SCHEMA_DEFAULT, false).
-endif.

%%-define(DBGFSM, true).

-ifdef(DBGFSM).

-define(FSMOPTS, [{debug, [trace]}]).

-else.

-define(FSMOPTS, []).

-endif.

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
start(Host) ->
    p1_fsm:start(ejabberd_sql, [Host],
		     fsm_limit_opts() ++ (?FSMOPTS)).

start_link(Host, StartInterval) ->
    p1_fsm:start_link(ejabberd_sql,
			  [Host, StartInterval],
			  fsm_limit_opts() ++ (?FSMOPTS)).

-type sql_query() :: [sql_query() | binary()] | #sql_query{} |
                     fun(() -> any()) | fun((atom(), _) -> any()).
-type sql_query_result() :: {updated, non_neg_integer()} |
                            {error, binary()} |
                            {selected, [binary()],
                             [[binary()]]} |
                            {selected, [any()]}.

-spec sql_query(binary(), sql_query()) -> sql_query_result().

sql_query(Host, Query) ->
    check_error(sql_call(Host, {sql_query, Query}), Query).

%% SQL transaction based on a list of queries
%% This function automatically
-spec sql_transaction(binary(), [sql_query()] | fun(() -> any())) ->
                             {atomic, any()} |
                             {aborted, any()}.

sql_transaction(Host, Queries)
    when is_list(Queries) ->
    F = fun () ->
		lists:foreach(fun (Query) -> sql_query_t(Query) end,
			      Queries)
	end,
    sql_transaction(Host, F);
%% SQL transaction, based on a erlang anonymous function (F = fun)
sql_transaction(Host, F) when is_function(F) ->
    sql_call(Host, {sql_transaction, F}).

%% SQL bloc, based on a erlang anonymous function (F = fun)
sql_bloc(Host, F) -> sql_call(Host, {sql_bloc, F}).

sql_call(Host, Msg) ->
    case get(?STATE_KEY) of
      undefined ->
        case ejabberd_sql_sup:get_random_pid(Host) of
          none -> {error, <<"Unknown Host">>};
          Pid ->
		sync_send_event(Pid,{sql_cmd, Msg,
				     p1_time_compat:monotonic_time(milli_seconds)},
				query_timeout(Host))
          end;
      _State -> nested_op(Msg)
    end.

keep_alive(Host, PID) ->
    sync_send_event(PID,
		    {sql_cmd, {sql_query, ?KEEPALIVE_QUERY},
		     p1_time_compat:monotonic_time(milli_seconds)},
		    query_timeout(Host)).

sync_send_event(Pid, Msg, Timeout) ->
    try p1_fsm:sync_send_event(Pid, Msg, Timeout)
    catch _:{Reason, {p1_fsm, _, _}} ->
	    {error, Reason}
    end.

-spec sql_query_t(sql_query()) -> sql_query_result().

%% This function is intended to be used from inside an sql_transaction:
sql_query_t(Query) ->
    QRes = sql_query_internal(Query),
    case QRes of
      {error, Reason} -> throw({aborted, Reason});
      Rs when is_list(Rs) ->
	  case lists:keysearch(error, 1, Rs) of
	    {value, {error, Reason}} -> throw({aborted, Reason});
	    _ -> QRes
	  end;
      _ -> QRes
    end.

abort(Reason) ->
    exit(Reason).

restart(Reason) ->
    throw({aborted, Reason}).

-spec escape_char(char()) -> binary().
escape_char($\000) -> <<"\\0">>;
escape_char($\n) -> <<"\\n">>;
escape_char($\t) -> <<"\\t">>;
escape_char($\b) -> <<"\\b">>;
escape_char($\r) -> <<"\\r">>;
escape_char($') -> <<"''">>;
escape_char($") -> <<"\\\"">>;
escape_char($\\) -> <<"\\\\">>;
escape_char(C) -> <<C>>.

-spec escape(binary()) -> binary().
escape(S) ->
	<<  <<(escape_char(Char))/binary>> || <<Char>> <= S >>.

%% Escape character that will confuse an SQL engine
%% Percent and underscore only need to be escaped for pattern matching like
%% statement
escape_like(S) when is_binary(S) ->
    << <<(escape_like(C))/binary>> || <<C>> <= S >>;
escape_like($%) -> <<"\\%">>;
escape_like($_) -> <<"\\_">>;
escape_like($\\) -> <<"\\\\\\\\">>;
escape_like(C) when is_integer(C), C >= 0, C =< 255 -> escape_char(C).

escape_like_arg(S) when is_binary(S) ->
    << <<(escape_like_arg(C))/binary>> || <<C>> <= S >>;
escape_like_arg($%) -> <<"\\%">>;
escape_like_arg($_) -> <<"\\_">>;
escape_like_arg($\\) -> <<"\\\\">>;
escape_like_arg(C) when is_integer(C), C >= 0, C =< 255 -> <<C>>.

escape_like_arg_circumflex(S) when is_binary(S) ->
    << <<(escape_like_arg_circumflex(C))/binary>> || <<C>> <= S >>;
escape_like_arg_circumflex($%) -> <<"^%">>;
escape_like_arg_circumflex($_) -> <<"^_">>;
escape_like_arg_circumflex($^) -> <<"^^">>;
escape_like_arg_circumflex($[) -> <<"^[">>;     % For MSSQL
escape_like_arg_circumflex($]) -> <<"^]">>;
escape_like_arg_circumflex(C) when is_integer(C), C >= 0, C =< 255 -> <<C>>.

to_bool(<<"t">>) -> true;
to_bool(<<"true">>) -> true;
to_bool(<<"1">>) -> true;
to_bool(true) -> true;
to_bool(1) -> true;
to_bool(_) -> false.

encode_term(Term) ->
    escape(list_to_binary(
             erl_prettypr:format(erl_syntax:abstract(Term),
                                 [{paper, 65535}, {ribbon, 65535}]))).

decode_term(Bin) ->
    Str = binary_to_list(<<Bin/binary, ".">>),
    {ok, Tokens, _} = erl_scan:string(Str),
    {ok, Term} = erl_parse:parse_term(Tokens),
    Term.

-spec sqlite_db(binary()) -> atom().
sqlite_db(Host) ->
    list_to_atom("ejabberd_sqlite_" ++ binary_to_list(Host)).

-spec sqlite_file(binary()) -> string().
sqlite_file(Host) ->
    case ejabberd_config:get_option({sql_database, Host}) of
	undefined ->
	    {ok, Cwd} = file:get_cwd(),
	    filename:join([Cwd, "sqlite", atom_to_list(node()),
			   binary_to_list(Host), "ejabberd.db"]);
	File ->
	    binary_to_list(File)
    end.

use_new_schema() ->
    ejabberd_config:get_option(new_sql_schema, ?USE_NEW_SCHEMA_DEFAULT).

%%%----------------------------------------------------------------------
%%% Callback functions from gen_fsm
%%%----------------------------------------------------------------------
init([Host, StartInterval]) ->
    process_flag(trap_exit, true),
    case ejabberd_config:get_option({sql_keepalive_interval, Host}) of
        undefined ->
            ok;
        KeepaliveInterval ->
            timer:apply_interval(KeepaliveInterval * 1000, ?MODULE,
                                 keep_alive, [Host, self()])
    end,
    [DBType | _] = db_opts(Host),
    p1_fsm:send_event(self(), connect),
    ejabberd_sql_sup:add_pid(Host, self()),
    QueueType = case ejabberd_config:get_option({sql_queue_type, Host}) of
		    undefined ->
			ejabberd_config:default_queue_type(Host);
		    Type ->
			Type
		end,
    {ok, connecting,
     #state{db_type = DBType, host = Host,
	    pending_requests = p1_queue:new(QueueType, max_fsm_queue()),
	    start_interval = StartInterval}}.

connecting(connect, #state{host = Host} = State) ->
    ConnectRes = case db_opts(Host) of
		   [mysql | Args] -> apply(fun mysql_connect/8, Args);
           [pgsql | Args] -> apply(fun pgsql_connect/8, Args);
           [sqlite | Args] -> apply(fun sqlite_connect/1, Args);
		   [mssql | Args] -> apply(fun odbc_connect/2, Args);
		   [odbc | Args] -> apply(fun odbc_connect/2, Args)
		 end,
    case ConnectRes of
        {ok, Ref} ->
            erlang:monitor(process, Ref),
            lists:foreach(
              fun({{?PREPARE_KEY, _} = Key, _}) ->
                      erase(Key);
                 (_) ->
                      ok
              end, get()),
	    PendingRequests =
		p1_queue:dropwhile(
		  fun(Req) ->
			  p1_fsm:send_event(self(), Req),
			  true
		  end, State#state.pending_requests),
            State1 = State#state{db_ref = Ref,
                                 pending_requests = PendingRequests},
            State2 = get_db_version(State1),
            {next_state, session_established, State2};
      {error, Reason} ->
	  ?INFO_MSG("~p connection failed:~n** Reason: ~p~n** "
		    "Retry after: ~p seconds",
		    [State#state.db_type, Reason,
		     State#state.start_interval div 1000]),
	  p1_fsm:send_event_after(State#state.start_interval,
				      connect),
	  {next_state, connecting, State}
    end;
connecting(Event, State) ->
    ?WARNING_MSG("unexpected event in 'connecting': ~p",
		 [Event]),
    {next_state, connecting, State}.

connecting({sql_cmd, {sql_query, ?KEEPALIVE_QUERY},
	    _Timestamp},
	   From, State) ->
    p1_fsm:reply(From,
		     {error, <<"SQL connection failed">>}),
    {next_state, connecting, State};
connecting({sql_cmd, Command, Timestamp} = Req, From,
	   State) ->
    ?DEBUG("queuing pending request while connecting:~n\t~p",
	   [Req]),
    PendingRequests =
	try p1_queue:in({sql_cmd, Command, From, Timestamp},
			State#state.pending_requests)
	catch error:full ->
		Q = p1_queue:dropwhile(
		      fun({sql_cmd, _, To, _Timestamp}) ->
			      p1_fsm:reply(
				To, {error, <<"SQL connection failed">>}),
			      true
		      end, State#state.pending_requests),
		p1_queue:in({sql_cmd, Command, From, Timestamp}, Q)
	end,
    {next_state, connecting,
     State#state{pending_requests = PendingRequests}};
connecting(Request, {Who, _Ref}, State) ->
    ?WARNING_MSG("unexpected call ~p from ~p in 'connecting'",
		 [Request, Who]),
    {reply, {error, badarg}, connecting, State}.

session_established({sql_cmd, Command, Timestamp}, From,
		    State) ->
    run_sql_cmd(Command, From, State, Timestamp);
session_established(Request, {Who, _Ref}, State) ->
    ?WARNING_MSG("unexpected call ~p from ~p in 'session_establ"
		 "ished'",
		 [Request, Who]),
    {reply, {error, badarg}, session_established, State}.

session_established({sql_cmd, Command, From, Timestamp},
		    State) ->
    run_sql_cmd(Command, From, State, Timestamp);
session_established(Event, State) ->
    ?WARNING_MSG("unexpected event in 'session_established': ~p",
		 [Event]),
    {next_state, session_established, State}.

handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(_Event, _From, StateName, State) ->
    {reply, {error, badarg}, StateName, State}.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%% We receive the down signal when we loose the MySQL connection (we are
%% monitoring the connection)
handle_info({'DOWN', _MonitorRef, process, _Pid, _Info},
	    _StateName, State) ->
    p1_fsm:send_event(self(), connect),
    {next_state, connecting, State};
handle_info(Info, StateName, State) ->
    ?WARNING_MSG("unexpected info in ~p: ~p",
		 [StateName, Info]),
    {next_state, StateName, State}.

terminate(_Reason, _StateName, State) ->
    ejabberd_sql_sup:remove_pid(State#state.host, self()),
    case State#state.db_type of
        mysql -> catch p1_mysql_conn:stop(State#state.db_ref);
        sqlite -> catch sqlite3:close(sqlite_db(State#state.host));
        _ -> ok
    end,
    ok.

%%----------------------------------------------------------------------
%% Func: print_state/1
%% Purpose: Prepare the state to be printed on error log
%% Returns: State to print
%%----------------------------------------------------------------------
print_state(State) -> State.

%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------

run_sql_cmd(Command, From, State, Timestamp) ->
    QueryTimeout = query_timeout(State#state.host),
    case p1_time_compat:monotonic_time(milli_seconds) - Timestamp of
      Age when Age < QueryTimeout ->
	  put(?NESTING_KEY, ?TOP_LEVEL_TXN),
	  put(?STATE_KEY, State),
	  abort_on_driver_error(outer_op(Command), From);
      Age ->
	  ?ERROR_MSG("Database was not available or too slow, "
		     "discarding ~p milliseconds old request~n~p~n",
		     [Age, Command]),
	  {next_state, session_established, State}
    end.

%% Only called by handle_call, only handles top level operations.
%% @spec outer_op(Op) -> {error, Reason} | {aborted, Reason} | {atomic, Result}
outer_op({sql_query, Query}) ->
    sql_query_internal(Query);
outer_op({sql_transaction, F}) ->
    outer_transaction(F, ?MAX_TRANSACTION_RESTARTS, <<"">>);
outer_op({sql_bloc, F}) -> execute_bloc(F).

%% Called via sql_query/transaction/bloc from client code when inside a
%% nested operation
nested_op({sql_query, Query}) ->
    sql_query_internal(Query);
nested_op({sql_transaction, F}) ->
    NestingLevel = get(?NESTING_KEY),
    if NestingLevel =:= (?TOP_LEVEL_TXN) ->
	   outer_transaction(F, ?MAX_TRANSACTION_RESTARTS, <<"">>);
       true -> inner_transaction(F)
    end;
nested_op({sql_bloc, F}) -> execute_bloc(F).

%% Never retry nested transactions - only outer transactions
inner_transaction(F) ->
    PreviousNestingLevel = get(?NESTING_KEY),
    case get(?NESTING_KEY) of
      ?TOP_LEVEL_TXN ->
	  {backtrace, T} = process_info(self(), backtrace),
	  ?ERROR_MSG("inner transaction called at outer txn "
		     "level. Trace: ~s",
		     [T]),
	  erlang:exit(implementation_faulty);
      _N -> ok
    end,
    put(?NESTING_KEY, PreviousNestingLevel + 1),
    Result = (catch F()),
    put(?NESTING_KEY, PreviousNestingLevel),
    case Result of
      {aborted, Reason} -> {aborted, Reason};
      {'EXIT', Reason} -> {'EXIT', Reason};
      {atomic, Res} -> {atomic, Res};
      Res -> {atomic, Res}
    end.

outer_transaction(F, NRestarts, _Reason) ->
    PreviousNestingLevel = get(?NESTING_KEY),
    case get(?NESTING_KEY) of
      ?TOP_LEVEL_TXN -> ok;
      _N ->
	  {backtrace, T} = process_info(self(), backtrace),
	  ?ERROR_MSG("outer transaction called at inner txn "
		     "level. Trace: ~s",
		     [T]),
	  erlang:exit(implementation_faulty)
    end,
    sql_query_internal([<<"begin;">>]),
    put(?NESTING_KEY, PreviousNestingLevel + 1),
    Result = (catch F()),
    put(?NESTING_KEY, PreviousNestingLevel),
    case Result of
      {aborted, Reason} when NRestarts > 0 ->
	  sql_query_internal([<<"rollback;">>]),
	  outer_transaction(F, NRestarts - 1, Reason);
      {aborted, Reason} when NRestarts =:= 0 ->
	  ?ERROR_MSG("SQL transaction restarts exceeded~n** "
		     "Restarts: ~p~n** Last abort reason: "
		     "~p~n** Stacktrace: ~p~n** When State "
		     "== ~p",
		     [?MAX_TRANSACTION_RESTARTS, Reason,
		      erlang:get_stacktrace(), get(?STATE_KEY)]),
	  sql_query_internal([<<"rollback;">>]),
	  {aborted, Reason};
      {'EXIT', Reason} ->
	  sql_query_internal([<<"rollback;">>]), {aborted, Reason};
      Res -> sql_query_internal([<<"commit;">>]), {atomic, Res}
    end.

execute_bloc(F) ->
    case catch F() of
      {aborted, Reason} -> {aborted, Reason};
      {'EXIT', Reason} -> {aborted, Reason};
      Res -> {atomic, Res}
    end.

execute_fun(F) when is_function(F, 0) ->
    F();
execute_fun(F) when is_function(F, 2) ->
    State = get(?STATE_KEY),
    F(State#state.db_type, State#state.db_version).

sql_query_internal([{_, _} | _] = Queries) ->
    State = get(?STATE_KEY),
    case select_sql_query(Queries, State) of
        undefined ->
            {error, <<"no matching query for the current DBMS found">>};
        Query ->
            sql_query_internal(Query)
    end;
sql_query_internal(#sql_query{} = Query) ->
    State = get(?STATE_KEY),
    Res =
        try
            case State#state.db_type of
                odbc ->
                    generic_sql_query(Query);
		mssql ->
		    mssql_sql_query(Query);
                pgsql ->
                    Key = {?PREPARE_KEY, Query#sql_query.hash},
                    case get(Key) of
                        undefined ->
                            case pgsql_prepare(Query, State) of
                                {ok, _, _, _} ->
                                    put(Key, prepared);
                                {error, Error} ->
                                    ?ERROR_MSG("PREPARE failed for SQL query "
                                               "at ~p: ~p",
                                               [Query#sql_query.loc, Error]),
                                    put(Key, ignore)
                            end;
                        _ ->
                            ok
                    end,
                    case get(Key) of
                        prepared ->
                            pgsql_execute_sql_query(Query, State);
                        _ ->
                            generic_sql_query(Query)
                    end;
                mysql ->
                    generic_sql_query(Query);
                sqlite ->
                    sqlite_sql_query(Query)
            end
        catch
            Class:Reason ->
                ST = erlang:get_stacktrace(),
                ?ERROR_MSG("Internal error while processing SQL query: ~p",
                           [{Class, Reason, ST}]),
                {error, <<"internal error">>}
        end,
    case Res of
        {error, <<"No SQL-driver information available.">>} ->
            {updated, 0};
        _Else -> Res
    end;
sql_query_internal(F) when is_function(F) ->
    case catch execute_fun(F) of
        {'EXIT', Reason} -> {error, Reason};
        Res -> Res
    end;
sql_query_internal(Query) ->
    State = get(?STATE_KEY),
    ?DEBUG("SQL: \"~s\"", [Query]),
    QueryTimeout = query_timeout(State#state.host),
    Res = case State#state.db_type of
	    odbc ->
		to_odbc(odbc:sql_query(State#state.db_ref, [Query],
                                       QueryTimeout - 1000));
	    mssql ->
		to_odbc(odbc:sql_query(State#state.db_ref, [Query],
                                       QueryTimeout - 1000));
	    pgsql ->
		pgsql_to_odbc(pgsql:squery(State#state.db_ref, Query,
					   QueryTimeout - 1000));
	    mysql ->
		R = mysql_to_odbc(p1_mysql_conn:squery(State#state.db_ref,
						   [Query], self(),
						   [{timeout, QueryTimeout - 1000},
						    {result_type, binary}])),
		%% ?INFO_MSG("MySQL, Received result~n~p~n", [R]),
		  R;
	      sqlite ->
		  Host = State#state.host,
		  sqlite_to_odbc(Host, sqlite3:sql_exec(sqlite_db(Host), Query))
	  end,
    case Res of
      {error, <<"No SQL-driver information available.">>} ->
	  {updated, 0};
      _Else -> Res
    end.

select_sql_query(Queries, State) ->
    select_sql_query(
      Queries, State#state.db_type, State#state.db_version, undefined).

select_sql_query([], _Type, _Version, undefined) ->
    undefined;
select_sql_query([], _Type, _Version, Query) ->
    Query;
select_sql_query([{any, Query} | _], _Type, _Version, _) ->
    Query;
select_sql_query([{Type, Query} | _], Type, _Version, _) ->
    Query;
select_sql_query([{{Type, _Version1}, Query1} | Rest], Type, undefined, _) ->
    select_sql_query(Rest, Type, undefined, Query1);
select_sql_query([{{Type, Version1}, Query1} | Rest], Type, Version, Query) ->
    if
        Version >= Version1 ->
            Query1;
        true ->
            select_sql_query(Rest, Type, Version, Query)
    end;
select_sql_query([{_, _} | Rest], Type, Version, Query) ->
    select_sql_query(Rest, Type, Version, Query).

generic_sql_query(SQLQuery) ->
    sql_query_format_res(
      sql_query_internal(generic_sql_query_format(SQLQuery)),
      SQLQuery).

generic_sql_query_format(SQLQuery) ->
    Args = (SQLQuery#sql_query.args)(generic_escape()),
    (SQLQuery#sql_query.format_query)(Args).

generic_escape() ->
    #sql_escape{string = fun(X) -> <<"'", (escape(X))/binary, "'">> end,
                integer = fun(X) -> misc:i2l(X) end,
                boolean = fun(true) -> <<"1">>;
                             (false) -> <<"0">>
                          end
               }.

sqlite_sql_query(SQLQuery) ->
    sql_query_format_res(
      sql_query_internal(sqlite_sql_query_format(SQLQuery)),
      SQLQuery).

sqlite_sql_query_format(SQLQuery) ->
    Args = (SQLQuery#sql_query.args)(sqlite_escape()),
    (SQLQuery#sql_query.format_query)(Args).

sqlite_escape() ->
    #sql_escape{string = fun(X) -> <<"'", (standard_escape(X))/binary, "'">> end,
                integer = fun(X) -> misc:i2l(X) end,
                boolean = fun(true) -> <<"1">>;
                             (false) -> <<"0">>
                          end
               }.

standard_escape(S) ->
    << <<(case Char of
              $' -> << "''" >>;
              _ -> << Char >>
          end)/binary>> || <<Char>> <= S >>.

mssql_sql_query(SQLQuery) ->
    sqlite_sql_query(SQLQuery).

pgsql_prepare(SQLQuery, State) ->
    Escape = #sql_escape{_ = fun(X) -> X end},
    N = length((SQLQuery#sql_query.args)(Escape)),
    Args = [<<$$, (integer_to_binary(I))/binary>> || I <- lists:seq(1, N)],
    Query = (SQLQuery#sql_query.format_query)(Args),
    pgsql:prepare(State#state.db_ref, SQLQuery#sql_query.hash, Query).

pgsql_execute_escape() ->
    #sql_escape{string = fun(X) -> X end,
                integer = fun(X) -> [misc:i2l(X)] end,
                boolean = fun(true) -> "1";
                             (false) -> "0"
                          end
               }.

pgsql_execute_sql_query(SQLQuery, State) ->
    Args = (SQLQuery#sql_query.args)(pgsql_execute_escape()),
    ExecuteRes =
        pgsql:execute(State#state.db_ref, SQLQuery#sql_query.hash, Args),
%    {T, ExecuteRes} =
%        timer:tc(pgsql, execute, [State#state.db_ref, SQLQuery#sql_query.hash, Args]),
%    io:format("T ~s ~p~n", [SQLQuery#sql_query.hash, T]),
    Res = pgsql_execute_to_odbc(ExecuteRes),
    sql_query_format_res(Res, SQLQuery).


sql_query_format_res({selected, _, Rows}, SQLQuery) ->
    Res =
        lists:flatmap(
          fun(Row) ->
                  try
                      [(SQLQuery#sql_query.format_res)(Row)]
                  catch
                      Class:Reason ->
                          ST = erlang:get_stacktrace(),
                          ?ERROR_MSG("Error while processing "
                                     "SQL query result: ~p~n"
                                     "row: ~p",
                                     [{Class, Reason, ST}, Row]),
                          []
                  end
          end, Rows),
    {selected, Res};
sql_query_format_res(Res, _SQLQuery) ->
    Res.

sql_query_to_iolist(SQLQuery) ->
    generic_sql_query_format(SQLQuery).

%% Generate the OTP callback return tuple depending on the driver result.
abort_on_driver_error({error, <<"query timed out">>} =
			  Reply,
		      From) ->
    p1_fsm:reply(From, Reply),
    {stop, timeout, get(?STATE_KEY)};
abort_on_driver_error({error,
		       <<"Failed sending data on socket", _/binary>>} =
			  Reply,
		      From) ->
    p1_fsm:reply(From, Reply),
    {stop, closed, get(?STATE_KEY)};
abort_on_driver_error(Reply, From) ->
    p1_fsm:reply(From, Reply),
    {next_state, session_established, get(?STATE_KEY)}.

%% == pure ODBC code

%% part of init/1
%% Open an ODBC database connection
odbc_connect(SQLServer, Timeout) ->
    ejabberd:start_app(odbc),
    odbc:connect(binary_to_list(SQLServer),
		 [{scrollable_cursors, off},
		  {tuple_row, off},
		  {timeout, Timeout},
		  {binary_strings, on}]).

%% == Native SQLite code

%% part of init/1
%% Open a database connection to SQLite

sqlite_connect(Host) ->
    File = sqlite_file(Host),
    case filelib:ensure_dir(File) of
	ok ->
	    case sqlite3:open(sqlite_db(Host), [{file, File}]) of
		{ok, Ref} ->
		    sqlite3:sql_exec(
		      sqlite_db(Host), "pragma foreign_keys = on"),
		    {ok, Ref};
		{error, {already_started, Ref}} ->
		    {ok, Ref};
		{error, Reason} ->
		    {error, Reason}
	    end;
	Err ->
	    Err
    end.

%% Convert SQLite query result to Erlang ODBC result formalism
sqlite_to_odbc(Host, ok) ->
    {updated, sqlite3:changes(sqlite_db(Host))};
sqlite_to_odbc(Host, {rowid, _}) ->
    {updated, sqlite3:changes(sqlite_db(Host))};
sqlite_to_odbc(_Host, [{columns, Columns}, {rows, TRows}]) ->
    Rows = [lists:map(
	      fun(I) when is_integer(I) ->
		      integer_to_binary(I);
		 (B) ->
		      B
	      end, tuple_to_list(Row)) || Row <- TRows],
    {selected, [list_to_binary(C) || C <- Columns], Rows};
sqlite_to_odbc(_Host, {error, _Code, Reason}) ->
    {error, Reason};
sqlite_to_odbc(_Host, _) ->
    {updated, undefined}.

%% == Native PostgreSQL code

%% part of init/1
%% Open a database connection to PostgreSQL
pgsql_connect(Server, Port, DB, Username, Password, ConnectTimeout,
	      Transport, SSLOpts) ->
    case pgsql:connect([{host, Server},
                        {database, DB},
                        {user, Username},
                        {password, Password},
                        {port, Port},
			{transport, Transport},
			{connect_timeout, ConnectTimeout},
                        {as_binary, true}|SSLOpts]) of
        {ok, Ref} ->
            pgsql:squery(Ref, [<<"alter database \"">>, DB, <<"\" set ">>,
                               <<"standard_conforming_strings='off';">>]),
            pgsql:squery(Ref, [<<"set standard_conforming_strings to 'off';">>]),
            {ok, Ref};
        Err ->
            Err
    end.

%% Convert PostgreSQL query result to Erlang ODBC result formalism
pgsql_to_odbc({ok, PGSQLResult}) ->
    case PGSQLResult of
      [Item] -> pgsql_item_to_odbc(Item);
      Items -> [pgsql_item_to_odbc(Item) || Item <- Items]
    end.

pgsql_item_to_odbc({<<"SELECT", _/binary>>, Rows,
		    Recs}) ->
    {selected, [element(1, Row) || Row <- Rows], Recs};
pgsql_item_to_odbc({<<"FETCH", _/binary>>, Rows,
		    Recs}) ->
    {selected, [element(1, Row) || Row <- Rows], Recs};
pgsql_item_to_odbc(<<"INSERT ", OIDN/binary>>) ->
    [_OID, N] = str:tokens(OIDN, <<" ">>),
    {updated, binary_to_integer(N)};
pgsql_item_to_odbc(<<"DELETE ", N/binary>>) ->
    {updated, binary_to_integer(N)};
pgsql_item_to_odbc(<<"UPDATE ", N/binary>>) ->
    {updated, binary_to_integer(N)};
pgsql_item_to_odbc({error, Error}) -> {error, Error};
pgsql_item_to_odbc(_) -> {updated, undefined}.

pgsql_execute_to_odbc({ok, {<<"SELECT", _/binary>>, Rows}}) ->
    {selected, [], [[Field || {_, Field} <- Row] || Row <- Rows]};
pgsql_execute_to_odbc({ok, {'INSERT', N}}) ->
    {updated, N};
pgsql_execute_to_odbc({ok, {'DELETE', N}}) ->
    {updated, N};
pgsql_execute_to_odbc({ok, {'UPDATE', N}}) ->
    {updated, N};
pgsql_execute_to_odbc({error, Error}) -> {error, Error};
pgsql_execute_to_odbc(_) -> {updated, undefined}.


%% == Native MySQL code

%% part of init/1
%% Open a database connection to MySQL
mysql_connect(Server, Port, DB, Username, Password, ConnectTimeout,  _, _) ->
    case p1_mysql_conn:start(binary_to_list(Server), Port,
			     binary_to_list(Username),
			     binary_to_list(Password),
			     binary_to_list(DB),
			     ConnectTimeout, fun log/3)
	of
	{ok, Ref} ->
	    p1_mysql_conn:fetch(
		Ref, [<<"set names 'utf8mb4' collate 'utf8mb4_bin';">>], self()),
	    {ok, Ref};
	Err -> Err
    end.

%% Convert MySQL query result to Erlang ODBC result formalism
mysql_to_odbc({updated, MySQLRes}) ->
    {updated, p1_mysql:get_result_affected_rows(MySQLRes)};
mysql_to_odbc({data, MySQLRes}) ->
    mysql_item_to_odbc(p1_mysql:get_result_field_info(MySQLRes),
		       p1_mysql:get_result_rows(MySQLRes));
mysql_to_odbc({error, MySQLRes})
  when is_binary(MySQLRes) ->
    {error, MySQLRes};
mysql_to_odbc({error, MySQLRes})
  when is_list(MySQLRes) ->
    {error, list_to_binary(MySQLRes)};
mysql_to_odbc({error, MySQLRes}) ->
    {error, p1_mysql:get_result_reason(MySQLRes)};
mysql_to_odbc(ok) ->
    ok.


%% When tabular data is returned, convert it to the ODBC formalism
mysql_item_to_odbc(Columns, Recs) ->
    {selected, [element(2, Column) || Column <- Columns], Recs}.

to_odbc({selected, Columns, Recs}) ->
    Rows = [lists:map(
	      fun(I) when is_integer(I) ->
		      integer_to_binary(I);
		 (B) ->
		      B
	      end, Row) || Row <- Recs],
    {selected, [list_to_binary(C) || C <- Columns], Rows};
to_odbc({error, Reason}) when is_list(Reason) ->
    {error, list_to_binary(Reason)};
to_odbc(Res) ->
    Res.

get_db_version(#state{db_type = pgsql} = State) ->
    case pgsql:squery(State#state.db_ref,
                      <<"select current_setting('server_version_num')">>) of
        {ok, [{_, _, [[SVersion]]}]} ->
            case catch binary_to_integer(SVersion) of
                Version when is_integer(Version) ->
                    State#state{db_version = Version};
                Error ->
                    ?WARNING_MSG("error getting pgsql version: ~p", [Error]),
                    State
            end;
        Res ->
            ?WARNING_MSG("error getting pgsql version: ~p", [Res]),
            State
    end;
get_db_version(State) ->
    State.

log(Level, Format, Args) ->
    case Level of
      debug -> ?DEBUG(Format, Args);
      normal -> ?INFO_MSG(Format, Args);
      error -> ?ERROR_MSG(Format, Args)
    end.

db_opts(Host) ->
    Type = ejabberd_config:get_option({sql_type, Host}, odbc),
    Server = ejabberd_config:get_option({sql_server, Host}, <<"localhost">>),
    Timeout = timer:seconds(
		ejabberd_config:get_option({sql_connect_timeout, Host}, 5)),
    Transport = case ejabberd_config:get_option({sql_ssl, Host}, false) of
		    false -> tcp;
		    true -> ssl
		end,
    warn_if_ssl_unsupported(Transport, Type),
    case Type of
        odbc ->
            [odbc, Server, Timeout];
        sqlite ->
            [sqlite, Host];
        _ ->
            Port = ejabberd_config:get_option(
                     {sql_port, Host},
                     case Type of
			 mssql -> ?MSSQL_PORT;
                         mysql -> ?MYSQL_PORT;
                         pgsql -> ?PGSQL_PORT
                     end),
            DB = ejabberd_config:get_option({sql_database, Host},
                                            <<"ejabberd">>),
            User = ejabberd_config:get_option({sql_username, Host},
                                              <<"ejabberd">>),
            Pass = ejabberd_config:get_option({sql_password, Host},
                                              <<"">>),
	    SSLOpts = get_ssl_opts(Transport, Host),
	    case Type of
		mssql ->
		    [mssql, <<"DSN=", Host/binary, ";UID=", User/binary,
			      ";PWD=", Pass/binary>>, Timeout];
		_ ->
		    [Type, Server, Port, DB, User, Pass, Timeout, Transport, SSLOpts]
	    end
    end.

warn_if_ssl_unsupported(tcp, _) ->
    ok;
warn_if_ssl_unsupported(ssl, pgsql) ->
    ok;
warn_if_ssl_unsupported(ssl, Type) ->
    ?WARNING_MSG("SSL connection is not supported for ~s", [Type]).

get_ssl_opts(ssl, Host) ->
    Opts1 = case ejabberd_config:get_option({sql_ssl_certfile, Host}) of
		undefined -> [];
		CertFile -> [{certfile, CertFile}]
	    end,
    Opts2 = case ejabberd_config:get_option({sql_ssl_cafile, Host}) of
		undefined -> Opts1;
		CAFile -> [{cacertfile, CAFile}|Opts1]
	    end,
    case ejabberd_config:get_option({sql_ssl_verify, Host}, false) of
	true ->
	    case lists:keymember(cacertfile, 1, Opts2) of
		true ->
		    [{verify, verify_peer}|Opts2];
		false ->
		    ?WARNING_MSG("SSL verification is enabled for "
				 "SQL connection, but option "
				 "'sql_ssl_cafile' is not set; "
				 "verification will be disabled", []),
		    Opts2
	    end;
	false ->
	    Opts2
    end;
get_ssl_opts(tcp, _) ->
    [].

init_mssql(Host) ->
    Server = ejabberd_config:get_option({sql_server, Host}, <<"localhost">>),
    Port = ejabberd_config:get_option({sql_port, Host}, ?MSSQL_PORT),
    DB = ejabberd_config:get_option({sql_database, Host}, <<"ejabberd">>),
    FreeTDS = io_lib:fwrite("[~s]~n"
			    "\thost = ~s~n"
			    "\tport = ~p~n"
			    "\ttds version = 7.1~n",
			    [Host, Server, Port]),
    ODBCINST = io_lib:fwrite("[freetds]~n"
			     "Description = MSSQL connection~n"
			     "Driver = libtdsodbc.so~n"
			     "Setup = libtdsS.so~n"
			     "UsageCount = 1~n"
			     "FileUsage = 1~n", []),
    ODBCINI = io_lib:fwrite("[~s]~n"
			    "Description = MS SQL~n"
			    "Driver = freetds~n"
			    "Servername = ~s~n"
			    "Database = ~s~n"
			    "Port = ~p~n",
			    [Host, Host, DB, Port]),
    ?DEBUG("~s:~n~s", [freetds_config(), FreeTDS]),
    ?DEBUG("~s:~n~s", [odbcinst_config(), ODBCINST]),
    ?DEBUG("~s:~n~s", [odbc_config(), ODBCINI]),
    case filelib:ensure_dir(freetds_config()) of
	ok ->
	    try
		ok = file:write_file(freetds_config(), FreeTDS, [append]),
		ok = file:write_file(odbcinst_config(), ODBCINST),
		ok = file:write_file(odbc_config(), ODBCINI, [append]),
		os:putenv("ODBCSYSINI", tmp_dir()),
		os:putenv("FREETDS", freetds_config()),
		os:putenv("FREETDSCONF", freetds_config()),
		ok
	    catch error:{badmatch, {error, Reason} = Err} ->
		    ?ERROR_MSG("failed to create temporary files in ~s: ~s",
			       [tmp_dir(), file:format_error(Reason)]),
		    Err
	    end;
	{error, Reason} = Err ->
	    ?ERROR_MSG("failed to create temporary directory ~s: ~s",
		       [tmp_dir(), file:format_error(Reason)]),
	    Err
    end.

tmp_dir() ->
    case os:type() of
	{win32, _} -> filename:join([os:getenv("HOME"), "conf"]);
	_ -> filename:join(["/tmp", "ejabberd"])
    end.

odbc_config() ->
    filename:join(tmp_dir(), "odbc.ini").

freetds_config() ->
    filename:join(tmp_dir(), "freetds.conf").

odbcinst_config() ->
    filename:join(tmp_dir(), "odbcinst.ini").

max_fsm_queue() ->
    proplists:get_value(max_queue, fsm_limit_opts(), unlimited).

fsm_limit_opts() ->
    ejabberd_config:fsm_limit_opts([]).

query_timeout(LServer) ->
    timer:seconds(
      ejabberd_config:get_option({sql_query_timeout, LServer}, 60)).

check_error({error, Why} = Err, _Query) when Why == killed ->
    Err;
check_error({error, Why} = Err, #sql_query{} = Query) ->
    ?ERROR_MSG("SQL query '~s' at ~p failed: ~p",
               [Query#sql_query.hash, Query#sql_query.loc, Why]),
    Err;
check_error({error, Why} = Err, Query) ->
    case catch iolist_to_binary(Query) of
        SQuery when is_binary(SQuery) ->
            ?ERROR_MSG("SQL query '~s' failed: ~p", [SQuery, Why]);
        _ ->
            ?ERROR_MSG("SQL query ~p failed: ~p", [Query, Why])
    end,
    Err;
check_error(Result, _Query) ->
    Result.

-spec opt_type(sql_database) -> fun((binary()) -> binary());
	      (sql_keepalive_interval) -> fun((pos_integer()) -> pos_integer());
	      (sql_password) -> fun((binary()) -> binary());
	      (sql_port) -> fun((0..65535) -> 0..65535);
	      (sql_server) -> fun((binary()) -> binary());
	      (sql_username) -> fun((binary()) -> binary());
	      (sql_ssl) -> fun((boolean()) -> boolean());
	      (sql_ssl_verify) -> fun((boolean()) -> boolean());
	      (sql_ssl_certfile) -> fun((boolean()) -> boolean());
	      (sql_ssl_cafile) -> fun((boolean()) -> boolean());
	      (sql_query_timeout) -> fun((pos_integer()) -> pos_integer());
	      (sql_connect_timeout) -> fun((pos_integer()) -> pos_integer());
	      (sql_queue_type) -> fun((ram | file) -> ram | file);
	      (atom()) -> [atom()].
opt_type(sql_database) -> fun iolist_to_binary/1;
opt_type(sql_keepalive_interval) ->
    fun (I) when is_integer(I), I > 0 -> I end;
opt_type(sql_password) -> fun iolist_to_binary/1;
opt_type(sql_port) ->
    fun (P) when is_integer(P), P > 0, P < 65536 -> P end;
opt_type(sql_server) -> fun iolist_to_binary/1;
opt_type(sql_username) -> fun iolist_to_binary/1;
opt_type(sql_ssl) -> fun(B) when is_boolean(B) -> B end;
opt_type(sql_ssl_verify) -> fun(B) when is_boolean(B) -> B end;
opt_type(sql_ssl_certfile) -> fun ejabberd_pkix:try_certfile/1;
opt_type(sql_ssl_cafile) -> fun misc:try_read_file/1;
opt_type(sql_query_timeout) ->
    fun (I) when is_integer(I), I > 0 -> I end;
opt_type(sql_connect_timeout) ->
    fun (I) when is_integer(I), I > 0 -> I end;
opt_type(sql_queue_type) ->
    fun(ram) -> ram; (file) -> file end;
opt_type(new_sql_schema) -> fun(B) when is_boolean(B) -> B end;
opt_type(_) ->
    [sql_database, sql_keepalive_interval,
     sql_password, sql_port, sql_server,
     sql_username, sql_ssl, sql_ssl_verify, sql_ssl_certfile,
     sql_ssl_cafile, sql_queue_type, sql_query_timeout,
     sql_connect_timeout,
     new_sql_schema].
