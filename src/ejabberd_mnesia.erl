%%%----------------------------------------------------------------------
%%% File    : mnesia_mnesia.erl
%%% Author  : Christophe Romain <christophe.romain@process-one.net>
%%% Purpose : Handle configurable mnesia schema
%%% Created : 17 Nov 2016 by Christophe Romain <christophe.romain@process-one.net>
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

%%% This module should be used everywhere ejabberd creates a mnesia table
%%% to make the schema customizable without code change
%%% Just apply this change in ejabberd modules
%%% s/ejabberd_mnesia:create(?MODULE, /ejabberd_mnesia:create(?MODULE, /

-module(ejabberd_mnesia).
-author('christophe.romain@process-one.net').

-behaviour(gen_server).

-export([start/0, create/3, update/2, transform/2, transform/3,
	 dump_schema/0]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(STORAGE_TYPES, [disc_copies, disc_only_copies, ram_copies]).
-define(NEED_RESET, [local_content, type]).

-include("logger.hrl").

-record(state, {tables = #{} :: map(),
		schema = [] :: [{atom(), [{atom(), any()}]}]}).

start() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec create(module(), atom(), list()) -> any().
create(Module, Name, TabDef) ->
    gen_server:call(?MODULE, {create, Module, Name, TabDef},
		    %% Huge timeout is need to have enough
		    %% time to transform huge tables
		    timer:minutes(30)).

init([]) ->
    ejabberd_config:env_binary_to_list(mnesia, dir),
    MyNode = node(),
    DbNodes = mnesia:system_info(db_nodes),
    case lists:member(MyNode, DbNodes) of
	true ->
	    case mnesia:system_info(extra_db_nodes) of
		[] -> mnesia:create_schema([node()]);
		_ -> ok
	    end,
	    ejabberd:start_app(mnesia, permanent),
	    Schema = read_schema_file(),
	    {ok, #state{schema = Schema}};
	false ->
	    ?CRITICAL_MSG("Node name mismatch: I'm [~s], "
			  "the database is owned by ~p", [MyNode, DbNodes]),
	    ?CRITICAL_MSG("Either set ERLANG_NODE in ejabberdctl.cfg "
			  "or change node name in Mnesia", []),
	    {stop, node_name_mismatch}
    end.

handle_call({create, Module, Name, TabDef}, _From, State) ->
    case maps:get(Name, State#state.tables, undefined) of
	{TabDef, Result} ->
	    {reply, Result, State};
	_ ->
	    Result = do_create(Module, Name, TabDef, State#state.schema),
	    Tables = maps:put(Name, {TabDef, Result}, State#state.tables),
	    {reply, Result, State#state{tables = Tables}}
    end;
handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

do_create(Module, Name, TabDef, TabDefs) ->
    code:ensure_loaded(Module),
    Schema = schema(Name, TabDef, TabDefs),
    {attributes, Attrs} = lists:keyfind(attributes, 1, Schema),
    case catch mnesia:table_info(Name, attributes) of
	{'EXIT', _} ->
	    create(Name, TabDef);
	Attrs ->
	    case need_reset(Name, Schema) of
		true ->
		    reset(Name, Schema);
		false ->
		    case update(Name, Attrs, Schema) of
			{atomic, ok} ->
			    transform(Module, Name, Attrs, Attrs);
			Err ->
			    Err
		    end
	    end;
	OldAttrs ->
	    transform(Module, Name, OldAttrs, Attrs)
    end.

reset(Name, TabDef) ->
    ?INFO_MSG("Deleting Mnesia table '~s'", [Name]),
    mnesia_op(delete_table, [Name]),
    create(Name, TabDef).

update(Name, TabDef) ->
    {attributes, Attrs} = lists:keyfind(attributes, 1, TabDef),
    update(Name, Attrs, TabDef).

update(Name, Attrs, TabDef) ->
    case change_table_copy_type(Name, TabDef) of
	{atomic, ok} ->
	    CurrIndexes = [lists:nth(N-1, Attrs) ||
			      N <- mnesia:table_info(Name, index)],
	    NewIndexes = proplists:get_value(index, TabDef, []),
	    case delete_indexes(Name, CurrIndexes -- NewIndexes) of
		{atomic, ok} ->
		    add_indexes(Name, NewIndexes -- CurrIndexes);
		Err ->
		    Err
	    end;
	Err ->
	    Err
    end.

change_table_copy_type(Name, TabDef) ->
    CurrType = mnesia:table_info(Name, storage_type),
    NewType = case lists:filter(fun is_storage_type_option/1, TabDef) of
		  [{Type, _}|_] -> Type;
		  [] -> CurrType
	      end,
    if NewType /= CurrType ->
	    ?INFO_MSG("Changing Mnesia table '~s' from ~s to ~s",
		      [Name, CurrType, NewType]),
	    mnesia_op(change_table_copy_type, [Name, node(), NewType]);
       true ->
	    {atomic, ok}
    end.

delete_indexes(Name, [Index|Indexes]) ->
    ?INFO_MSG("Deleting index '~s' from Mnesia table '~s'", [Index, Name]),
    case mnesia_op(del_table_index, [Name, Index]) of
	{atomic, ok} ->
	    delete_indexes(Name, Indexes);
	Err ->
	    Err
    end;
delete_indexes(_Name, []) ->
    {atomic, ok}.

add_indexes(Name, [Index|Indexes]) ->
    ?INFO_MSG("Adding index '~s' to Mnesia table '~s'", [Index, Name]),
    case mnesia_op(add_table_index, [Name, Index]) of
	{atomic, ok} ->
	    add_indexes(Name, Indexes);
	Err ->
	    Err
    end;
add_indexes(_Name, []) ->
    {atomic, ok}.

%
% utilities
%

schema(Name, Default, Schema) ->
    case lists:keyfind(Name, 1, Schema) of
	{_, Custom} ->
	    TabDefs = merge(Custom, Default),
	    ?DEBUG("Using custom schema for table '~s': ~p",
		   [Name, TabDefs]),
	    TabDefs;
	false ->
	    ?DEBUG("No custom Mnesia schema for table '~s' found",
		   [Name]),
	    Default
    end.

read_schema_file() ->
    File = schema_path(),
    case fast_yaml:decode_from_file(File, [plain_as_atom]) of
	{ok, [Defs|_]} ->
	    ?INFO_MSG("Using custom Mnesia schema from ~s", [File]),
	    lists:flatmap(
	      fun({Tab, Opts}) ->
		      case validate_schema_opts(File, Opts) of
			  {ok, NewOpts} ->
			      [{Tab, lists:ukeysort(1, NewOpts)}];
			  error ->
			      []
		      end
	      end, Defs);
	{ok, []} ->
	    ?WARNING_MSG("Mnesia schema file ~s is empty", [File]),
	    [];
	{error, enoent} ->
	    ?DEBUG("No custom Mnesia schema file found", []),
	    [];
	{error, Reason} ->
	    ?ERROR_MSG("Failed to read Mnesia schema file ~s: ~s",
		       [File, fast_yaml:format_error(Reason)]),
	    []
    end.

validate_schema_opts(File, Opts) ->
    try {ok, lists:map(
	       fun({storage_type, Type}) when Type == ram_copies;
					      Type == disc_copies;
					      Type == disc_only_copies ->
		       {Type, [node()]};
		  ({storage_type, _} = Opt) ->
		       erlang:error({invalid_value, Opt});
		  ({local_content, Bool}) when is_boolean(Bool) ->
		       {local_content, Bool};
		  ({local_content, _} = Opt) ->
		       erlang:error({invalid_value, Opt});
		  ({type, Type}) when Type == set;
				      Type == ordered_set;
				      Type == bag ->
		       {type, Type};
		  ({type, _} = Opt) ->
		       erlang:error({invalid_value, Opt});
		  ({attributes, Attrs} = Opt) ->
		       try lists:all(fun is_atom/1, Attrs) of
			   true -> {attributes, Attrs};
			   false -> erlang:error({invalid_value, Opt})
		       catch _:_ -> erlang:error({invalid_value, Opt})
		       end;
		  ({index, Indexes} = Opt) ->
		       try lists:all(fun is_atom/1, Indexes) of
			   true -> {index, Indexes};
			   false -> erlang:error({invalid_value, Opt})
		       catch _:_ -> erlang:error({invalid_value, Opt})
		       end;
		  (Opt) ->
		       erlang:error({unknown_option, Opt})
	       end, Opts)}
    catch _:{invalid_value, {Opt, Val}} ->
	    ?ERROR_MSG("Mnesia schema ~s is incorrect: invalid value ~p of "
		       "option '~s'", [File, Val, Opt]),
	    error;
	  _:{unknown_option, Opt} ->
	    ?ERROR_MSG("Mnesia schema ~s is incorrect: unknown option ~p",
		       [File, Opt]),
	    error
    end.

create(Name, TabDef) ->
    ?INFO_MSG("Creating Mnesia table '~s'", [Name]),
    case mnesia_op(create_table, [Name, TabDef]) of
	{atomic, ok} ->
	    add_table_copy(Name);
	Err ->
	    Err
    end.

%% The table MUST exist, otherwise the function would fail
add_table_copy(Name) ->
    Type = mnesia:table_info(Name, storage_type),
    Nodes = mnesia:table_info(Name, Type),
    case lists:member(node(), Nodes) of
	true ->
	    {atomic, ok};
	false ->
	    mnesia_op(add_table_copy, [Name, node(), Type])
    end.

merge(Custom, Default) ->
    NewDefault = case lists:any(fun is_storage_type_option/1, Custom) of
		     true ->
			 lists:filter(
			   fun(O) ->
				   not is_storage_type_option(O)
			   end, Default);
		     false ->
			 Default
		 end,
    lists:ukeymerge(1, Custom, lists:ukeysort(1, NewDefault)).

need_reset(Table, TabDef) ->
    ValuesF = [mnesia:table_info(Table, Key) || Key <- ?NEED_RESET],
    ValuesT = [proplists:get_value(Key, TabDef) || Key <- ?NEED_RESET],
    lists:foldl(
      fun({Val, Val}, Acc) -> Acc;
	 ({_, undefined}, Acc) -> Acc;
	 ({_, _}, _) -> true
      end, false, lists:zip(ValuesF, ValuesT)).

transform(Module, Name) ->
    try mnesia:table_info(Name, attributes) of
	Attrs ->
	    transform(Module, Name, Attrs, Attrs)
    catch _:{aborted, _} = Err ->
	    Err
    end.

transform(Module, Name, NewAttrs) ->
    try mnesia:table_info(Name, attributes) of
	OldAttrs ->
	    transform(Module, Name, OldAttrs, NewAttrs)
    catch _:{aborted, _} = Err ->
	    Err
    end.

transform(Module, Name, Attrs, Attrs) ->
    case need_transform(Module, Name) of
	true ->
	    ?INFO_MSG("Transforming table '~s', this may take a while", [Name]),
	    transform_table(Module, Name);
	false ->
	    {atomic, ok}
    end;
transform(Module, Name, OldAttrs, NewAttrs) ->
    Fun = case erlang:function_exported(Module, transform, 1) of
	      true -> transform_fun(Module, Name);
	      false -> fun(Old) -> do_transform(OldAttrs, NewAttrs, Old) end
	  end,
    mnesia_op(transform_table, [Name, Fun, NewAttrs]).

-spec need_transform(module(), atom()) -> boolean().
need_transform(Module, Name) ->
    case erlang:function_exported(Module, need_transform, 1) of
	true ->
	    do_need_transform(Module, Name, mnesia:dirty_first(Name));
	false ->
	    false
    end.

do_need_transform(_Module, _Name, '$end_of_table') ->
    false;
do_need_transform(Module, Name, Key) ->
    Objs = mnesia:dirty_read(Name, Key),
    case lists:foldl(
	   fun(_, true) -> true;
	      (Obj, _) -> Module:need_transform(Obj)
	   end, undefined, Objs) of
	true -> true;
	false -> false;
	_ ->
	    do_need_transform(Module, Name, mnesia:dirty_next(Name, Key))
    end.

do_transform(OldAttrs, Attrs, Old) ->
    [Name|OldValues] = tuple_to_list(Old),
    Before = lists:zip(OldAttrs, OldValues),
    After = lists:foldl(
	      fun(Attr, Acc) ->
		      case lists:keyfind(Attr, 1, Before) of
			  false -> [{Attr, undefined}|Acc];
			  Value -> [Value|Acc]
		      end
	      end, [], lists:reverse(Attrs)),
    {Attrs, NewRecord} = lists:unzip(After),
    list_to_tuple([Name|NewRecord]).

transform_fun(Module, Name) ->
    fun(Obj) ->
	    try Module:transform(Obj)
	    catch E:R ->
		    StackTrace = erlang:get_stacktrace(),
		    ?ERROR_MSG("Failed to transform Mnesia table ~s:~n"
			       "** Record: ~p~n"
			       "** Reason: ~p~n"
			       "** StackTrace: ~p",
			       [Name, Obj, R, StackTrace]),
		    erlang:raise(E, R, StackTrace)
	    end
    end.

transform_table(Module, Name) ->
    Type = mnesia:table_info(Name, type),
    Attrs = mnesia:table_info(Name, attributes),
    TmpTab = list_to_atom(atom_to_list(Name) ++ "_backup"),
    StorageType = if Type == ordered_set -> disc_copies;
		     true -> disc_only_copies
		  end,
    mnesia:create_table(TmpTab,
			[{StorageType, [node()]},
			 {type, Type},
			 {local_content, true},
			 {record_name, Name},
			 {attributes, Attrs}]),
    mnesia:clear_table(TmpTab),
    Fun = transform_fun(Module, Name),
    Res = mnesia_op(
	    transaction,
	    [fun() -> do_transform_table(Name, Fun, TmpTab, mnesia:first(Name)) end]),
    mnesia:delete_table(TmpTab),
    Res.

do_transform_table(Name, _Fun, TmpTab, '$end_of_table') ->
    mnesia:foldl(
      fun(Obj, _) ->
	      mnesia:write(Name, Obj, write)
      end, ok, TmpTab);
do_transform_table(Name, Fun, TmpTab, Key) ->
    Next = mnesia:next(Name, Key),
    Objs = mnesia:read(Name, Key),
    lists:foreach(
      fun(Obj) ->
	      mnesia:write(TmpTab, Fun(Obj), write),
	      mnesia:delete_object(Obj)
      end, Objs),
    do_transform_table(Name, Fun, TmpTab, Next).

mnesia_op(Fun, Args) ->
    case apply(mnesia, Fun, Args) of
	{atomic, ok} ->
	    {atomic, ok};
	Other ->
	    ?ERROR_MSG("failure on mnesia ~s ~p: ~p",
		      [Fun, Args, Other]),
	    Other
    end.

schema_path() ->
    Dir = case os:getenv("EJABBERD_MNESIA_SCHEMA") of
	      false -> mnesia:system_info(directory);
	      Path -> Path
	  end,
    filename:join(Dir, "ejabberd.schema").

is_storage_type_option({O, _}) ->
    O == ram_copies orelse O == disc_copies orelse O == disc_only_copies.

dump_schema() ->
    File = schema_path(),
    Schema = lists:flatmap(
	       fun(schema) ->
		       [];
		  (Tab) ->
		       [{Tab, [{storage_type,
				mnesia:table_info(Tab, storage_type)},
			       {local_content,
				mnesia:table_info(Tab, local_content)}]}]
	       end, mnesia:system_info(tables)),
    case file:write_file(File, [fast_yaml:encode(Schema), io_lib:nl()]) of
	ok ->
	    io:format("Mnesia schema is written to ~s~n", [File]);
	{error, Reason} ->
	    io:format("Failed to write Mnesia schema to ~s: ~s",
		      [File, file:format_error(Reason)])
    end.
