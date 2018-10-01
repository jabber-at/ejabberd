%%%----------------------------------------------------------------------
%%% File    : ejabberd_config.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Load config file
%%% Created : 14 Dec 2002 by Alexey Shchepin <alexey@process-one.net>
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

-module(ejabberd_config).
-author('alexey@process-one.net').

-export([start/0, load_file/1, reload_file/0, read_file/1,
	 get_option/1, get_option/2, add_option/2, has_option/1,
	 get_version/0, get_myhosts/0, get_myname/0,
	 get_mylang/0, get_lang/1, get_uri/0, get_copyright/0,
	 get_ejabberd_config_path/0, is_using_elixir_config/0,
	 prepare_opt_val/4, transform_options/1, collect_options/1,
	 convert_to_yaml/1, convert_to_yaml/2, v_db/2,
	 env_binary_to_list/2, opt_type/1, may_hide_data/1,
	 is_elixir_enabled/0, v_dbs/1, v_dbs_mods/1, v_host/1, v_hosts/1,
	 default_db/1, default_db/2, default_ram_db/1, default_ram_db/2,
	 default_queue_type/1, queue_dir/0, fsm_limit_opts/1,
	 use_cache/1, cache_size/1, cache_missed/1, cache_life_time/1,
	 codec_options/1, get_plain_terms_file/2, negotiation_timeout/0]).

-export([start/2]).

%% The following functions are deprecated.
-export([add_global_option/2, add_local_option/2,
	 get_global_option/2, get_local_option/2,
	 get_global_option/3, get_local_option/3,
	 get_option/3]).
-export([is_file_readable/1]).

-deprecated([{add_global_option, 2}, {add_local_option, 2},
	     {get_global_option, 2}, {get_local_option, 2},
	     {get_global_option, 3}, {get_local_option, 3},
	     {get_option, 3}, {is_file_readable, 1}]).

-include("logger.hrl").
-include("ejabberd_config.hrl").
-include_lib("kernel/include/file.hrl").
-include_lib("kernel/include/inet.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

-callback opt_type(atom()) -> fun((any()) -> any()) | [atom()].
-type bad_option() :: invalid_option | unknown_option.

-spec start() -> ok | {error, bad_option()}.
start() ->
    ConfigFile = get_ejabberd_config_path(),
    ?INFO_MSG("Loading configuration from ~s", [ConfigFile]),
    catch ets:new(ejabberd_options,
		  [named_table, public, {read_concurrency, true}]),
    catch ets:new(ejabberd_db_modules,
		  [named_table, public, {read_concurrency, true}]),
    case load_file(ConfigFile) of
	{ok, State1} ->
	    UnixTime = p1_time_compat:system_time(seconds),
	    SharedKey = case erlang:get_cookie() of
			    nocookie ->
				str:sha(p1_rand:get_string());
			    Cookie ->
				str:sha(misc:atom_to_binary(Cookie))
			end,
	    State2 = set_option({node_start, global}, UnixTime, State1),
	    State3 = set_option({shared_key, global}, SharedKey, State2),
	    set_opts(State3),
	    ok;
	{error, _} = Err ->
	    ?ERROR_MSG("Failed to load configuration file ~s", [ConfigFile]),
	    Err
    end.

%% When starting ejabberd for testing, we sometimes want to start a
%% subset of hosts from the one define in the config file.
%% This function override the host list read from config file by the
%% one we provide.
%% Hosts to start are defined in an ejabberd application environment
%% variable 'hosts' to make it easy to ignore some host in config
%% file.
hosts_to_start(State) ->
    case application:get_env(ejabberd, hosts) of
        undefined ->
            %% Start all hosts as defined in config file
            State;
        {ok, Hosts} ->
            set_hosts_in_options(Hosts, State)
    end.

%% @private
%% At the moment, these functions are mainly used to setup unit tests.
-spec start(Hosts :: [binary()], Opts :: [acl:acl() | local_config()]) -> ok.
start(Hosts, Opts) ->
    catch ets:new(ejabberd_options,
		  [named_table, public, {read_concurrency, true}]),
    catch ets:new(ejabberd_db_modules,
		  [named_table, public, {read_concurrency, true}]),
    UnixTime = p1_time_compat:system_time(seconds),
    SharedKey = case erlang:get_cookie() of
		    nocookie ->
			str:sha(p1_rand:get_string());
		    Cookie ->
			str:sha(misc:atom_to_binary(Cookie))
		end,
    State1 = #state{opts = Opts},
    State2 = set_option({node_start, global}, UnixTime, State1),
    State3 = set_option({shared_key, global}, SharedKey, State2),
    set_opts(set_hosts_in_options(Hosts, State3)),
    ok.

%% @doc Get the filename of the ejabberd configuration file.
%% The filename can be specified with: erl -config "/path/to/ejabberd.yml".
%% It can also be specified with the environtment variable EJABBERD_CONFIG_PATH.
%% If not specified, the default value 'ejabberd.yml' is assumed.
%% @spec () -> string()
get_ejabberd_config_path() ->
    case get_env_config() of
	{ok, Path} -> Path;
	undefined ->
	    case os:getenv("EJABBERD_CONFIG_PATH") of
		false ->
		    "ejabberd.yml";
		Path ->
		    Path
	    end
    end.

-spec get_env_config() -> {ok, string()} | undefined.
get_env_config() ->
    %% First case: the filename can be specified with: erl -config "/path/to/ejabberd.yml".
    case application:get_env(ejabberd, config) of
	R = {ok, _Path} -> R;
	undefined ->
            %% Second case for embbeding ejabberd in another app, for example for Elixir:
            %% config :ejabberd,
            %%   file: "config/ejabberd.yml"
            application:get_env(ejabberd, file)
    end.

%% @doc Read the ejabberd configuration file.
%% It also includes additional configuration files and replaces macros.
%% This function will crash if finds some error in the configuration file.
%% @spec (File::string()) -> #state{}
read_file(File) ->
    read_file(File, [{replace_macros, true},
                     {include_files, true},
                     {include_modules_configs, true}]).

read_file(File, Opts) ->
    Terms1 = case is_elixir_enabled() of
		 true ->
		     case 'Elixir.Ejabberd.ConfigUtil':is_elixir_config(File) of
			 true ->
			     'Elixir.Ejabberd.Config':init(File),
			     'Elixir.Ejabberd.Config':get_ejabberd_opts();
			 false ->
			     get_plain_terms_file(File, Opts)
		     end;
		 false ->
		     get_plain_terms_file(File, Opts)
	     end,
    Terms_macros = case proplists:get_bool(replace_macros, Opts) of
                       true -> replace_macros(Terms1);
                       false -> Terms1
                   end,
    Terms = transform_terms(Terms_macros),
    State = lists:foldl(fun search_hosts/2, #state{}, Terms),
    {Head, Tail} = lists:partition(
                     fun({host_config, _}) -> false;
                        ({append_host_config, _}) -> false;
                        (_) -> true
                     end, Terms),
    State1 = lists:foldl(fun process_term/2, State, Head ++ Tail),
    State1#state{opts = compact(State1#state.opts)}.

-spec load_file(string()) -> {ok, #state{}} | {error, bad_option()}.

load_file(File) ->
    State0 = read_file(File),
    State1 = hosts_to_start(State0),
    AllMods = get_modules(),
    init_module_db_table(AllMods),
    ModOpts = get_modules_with_options(AllMods),
    validate_opts(State1, ModOpts).

-spec reload_file() -> ok | {error, bad_option()}.

reload_file() ->
    Config = get_ejabberd_config_path(),
    OldHosts = get_myhosts(),
    case load_file(Config) of
	{error, _} = Err ->
	    Err;
	{ok, State} ->
	    set_opts(State),
	    NewHosts = get_myhosts(),
	    lists:foreach(
	      fun(Host) ->
		      ejabberd_hooks:run(host_up, [Host])
	      end, NewHosts -- OldHosts),
	    lists:foreach(
	      fun(Host) ->
		      ejabberd_hooks:run(host_down, [Host])
	      end, OldHosts -- NewHosts),
	    ejabberd_hooks:run(config_reloaded, [])
    end.

-spec convert_to_yaml(file:filename()) -> ok | {error, any()}.

convert_to_yaml(File) ->
    convert_to_yaml(File, stdout).

-spec convert_to_yaml(file:filename(),
                      stdout | file:filename()) -> ok | {error, any()}.

convert_to_yaml(File, Output) ->
    State = read_file(File, [{include_files, false}]),
    Opts = [{K, V} || #local_config{key = K, value = V} <- State#state.opts],
    {GOpts, HOpts} = split_by_hosts(Opts),
    NewOpts = GOpts ++ lists:map(
                         fun({Host, Opts1}) ->
                                 {host_config, [{Host, Opts1}]}
                         end, HOpts),
    Data = fast_yaml:encode(lists:reverse(NewOpts)),
    case Output of
        stdout ->
            io:format("~s~n", [Data]);
        FileName ->
            file:write_file(FileName, Data)
    end.

%% Some Erlang apps expects env parameters to be list and not binary.
%% For example, Mnesia is not able to start if mnesia dir is passed as a binary.
%% However, binary is most common on Elixir, so it is easy to make a setup mistake.
-spec env_binary_to_list(atom(), atom()) -> {ok, any()}|undefined.
env_binary_to_list(Application, Parameter) ->
    %% Application need to be loaded to allow setting parameters
    application:load(Application),
    case application:get_env(Application, Parameter) of
        {ok, Val} when is_binary(Val) ->
            BVal = binary_to_list(Val),
            application:set_env(Application, Parameter, BVal),
            {ok, BVal};
        Other ->
            Other
    end.

%% @doc Read an ejabberd configuration file and return the terms.
%% Input is an absolute or relative path to an ejabberd config file.
%% Returns a list of plain terms,
%% in which the options 'include_config_file' were parsed
%% and the terms in those files were included.
%% @spec(iolist()) -> [term()]
get_plain_terms_file(File, Opts) when is_binary(File) ->
    get_plain_terms_file(binary_to_list(File), Opts);
get_plain_terms_file(File1, Opts) ->
    File = get_absolute_path(File1),
    DontStopOnError = lists:member(dont_halt_on_error, Opts),
    case consult(File) of
	{ok, Terms} ->
            BinTerms1 = strings_to_binary(Terms),
            ModInc = case proplists:get_bool(include_modules_configs, Opts) of
                         true ->
                            Files = [{filename:rootname(filename:basename(F)), F}
                                     || F <- filelib:wildcard(ext_mod:config_dir() ++ "/*.{yml,yaml}")
                                          ++ filelib:wildcard(ext_mod:modules_dir() ++ "/*/conf/*.{yml,yaml}")],
                            [proplists:get_value(F,Files) || F <- proplists:get_keys(Files)];
                         _ ->
                            []
                     end,
            BinTerms = BinTerms1 ++ [{include_config_file, list_to_binary(V)} || V <- ModInc],
            case proplists:get_bool(include_files, Opts) of
                true ->
                    include_config_files(BinTerms);
                false ->
                    BinTerms
            end;
  {error, enoent, Reason} ->
      case DontStopOnError of
          true ->
              ?WARNING_MSG(Reason, []),
              [];
          _ ->
	    ?ERROR_MSG(Reason, []),
	    exit_or_halt(Reason)
      end;
	{error, Reason} ->
	    ?ERROR_MSG(Reason, []),
      case DontStopOnError of
          true -> [];
          _ -> exit_or_halt(Reason)
      end
    end.

consult(File) ->
    case filename:extension(File) of
        Ex when (Ex == ".yml") or (Ex == ".yaml") ->
            case fast_yaml:decode_from_file(File, [plain_as_atom]) of
                {ok, []} ->
                    {ok, []};
                {ok, [Document|_]} ->
                    {ok, parserl(Document)};
                {error, Err} ->
                    Msg1 = "Cannot load " ++ File ++ ": ",
                    Msg2 = fast_yaml:format_error(Err),
                    case Err of
                        enoent ->
                            {error, enoent, Msg1 ++ Msg2};
                        _ ->
                    {error, Msg1 ++ Msg2}
                    end
            end;
        _ ->
            case file:consult(File) of
                {ok, Terms} ->
                    {ok, Terms};
                {error, {LineNumber, erl_parse, _ParseMessage} = Reason} ->
                    {error, describe_config_problem(File, Reason, LineNumber)};
                {error, Reason} ->
                    case Reason of
                        enoent ->
                            {error, enoent, describe_config_problem(File, Reason)};
                        _ ->
                    {error, describe_config_problem(File, Reason)}
            end
            end
    end.

parserl(<<"> ", Term/binary>>) ->
    {ok, A2, _} = erl_scan:string(binary_to_list(Term)),
    {ok, A3} = erl_parse:parse_term(A2),
    A3;
parserl({A, B}) ->
    {parserl(A), parserl(B)};
parserl([El|Tail]) ->
    [parserl(El) | parserl(Tail)];
parserl(Other) ->
    Other.

%% @doc Convert configuration filename to absolute path.
%% Input is an absolute or relative path to an ejabberd configuration file.
%% And returns an absolute path to the configuration file.
%% @spec (string()) -> string()
get_absolute_path(File) ->
    case filename:pathtype(File) of
	absolute ->
	    File;
	relative ->
	    {ok, Dir} = file:get_cwd(),
	    filename:absname_join(Dir, File);
	volumerelative ->
	    filename:absname(File)
    end.

search_hosts(Term, State) ->
    case Term of
	{host, Host} ->
	    if
		State#state.hosts == [] ->
		    set_hosts_in_options([Host], State);
		true ->
		    ?ERROR_MSG("Can't load config file: "
			       "too many hosts definitions", []),
		    exit("too many hosts definitions")
	    end;
	{hosts, Hosts} ->
	    if
		State#state.hosts == [] ->
		    set_hosts_in_options(Hosts, State);
		true ->
		    ?ERROR_MSG("Can't load config file: "
			       "too many hosts definitions", []),
		    exit("too many hosts definitions")
	    end;
	_ ->
	    State
    end.

set_hosts_in_options(Hosts, State) ->
    PrepHosts = normalize_hosts(Hosts),
    NewOpts = lists:filter(fun({local_config,{hosts,global},_}) -> false;
                               (_) -> true
                            end, State#state.opts),
    set_option({hosts, global}, PrepHosts, State#state{hosts = PrepHosts, opts = NewOpts}).

normalize_hosts(Hosts) ->
    normalize_hosts(Hosts,[]).
normalize_hosts([], PrepHosts) ->
    lists:reverse(PrepHosts);
normalize_hosts([Host|Hosts], PrepHosts) ->
    case jid:nodeprep(iolist_to_binary(Host)) of
	error ->
	    ?ERROR_MSG("Can't load config file: "
		       "invalid host name [~p]", [Host]),
	    exit("invalid hostname");
	PrepHost ->
	    normalize_hosts(Hosts, [PrepHost|PrepHosts])
    end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Errors reading the config file

describe_config_problem(Filename, Reason) ->
    Text1 = lists:flatten("Problem loading ejabberd config file " ++ Filename),
    Text2 = lists:flatten(" : " ++ file:format_error(Reason)),
    ExitText = Text1 ++ Text2,
    ExitText.

describe_config_problem(Filename, Reason, LineNumber) ->
    Text1 = lists:flatten("Problem loading ejabberd config file " ++ Filename),
    Text2 = lists:flatten(" approximately in the line "
			  ++ file:format_error(Reason)),
    ExitText = Text1 ++ Text2,
    Lines = get_config_lines(Filename, LineNumber, 10, 3),
    ?ERROR_MSG("The following lines from your configuration file might be"
	       " relevant to the error: ~n~s", [Lines]),
    ExitText.

get_config_lines(Filename, TargetNumber, PreContext, PostContext) ->
    {ok, Fd} = file:open(Filename, [read]),
    LNumbers = lists:seq(TargetNumber-PreContext, TargetNumber+PostContext),
    NextL = io:get_line(Fd, no_prompt),
    R = get_config_lines2(Fd, NextL, 1, LNumbers, []),
    file:close(Fd),
    R.

get_config_lines2(_Fd, eof, _CurrLine, _LNumbers, R) ->
    lists:reverse(R);
get_config_lines2(_Fd, _NewLine, _CurrLine, [], R) ->
    lists:reverse(R);
get_config_lines2(Fd, Data, CurrLine, [NextWanted | LNumbers], R) when is_list(Data) ->
    NextL = io:get_line(Fd, no_prompt),
    if
	CurrLine >= NextWanted ->
	    Line2 = [integer_to_list(CurrLine), ": " | Data],
	    get_config_lines2(Fd, NextL, CurrLine+1, LNumbers, [Line2 | R]);
	true ->
	    get_config_lines2(Fd, NextL, CurrLine+1, [NextWanted | LNumbers], R)
    end.

%% If ejabberd isn't yet running in this node, then halt the node
exit_or_halt(ExitText) ->
    case [Vsn || {ejabberd, _Desc, Vsn} <- application:which_applications()] of
	[] ->
	    ejabberd:halt();
	[_] ->
	    exit(ExitText)
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Support for 'include_config_file'

get_config_option_key(Name, Val) ->
    if Name == listen ->
            case Val of
                {{Port, IP, Trans}, _Mod, _Opts} ->
                    {Port, IP, Trans};
                {{Port, Trans}, _Mod, _Opts} when Trans == tcp; Trans == udp ->
                    {Port, {0,0,0,0}, Trans};
                {{Port, IP}, _Mod, _Opts} ->
                    {Port, IP, tcp};
                {Port, _Mod, _Opts} ->
                    {Port, {0,0,0,0}, tcp};
                V when is_list(V) ->
                    lists:foldl(
                      fun({port, Port}, {_, IP, T}) ->
                              {Port, IP, T};
                         ({ip, IP}, {Port, _, T}) ->
                              {Port, IP, T};
                         ({transport, T}, {Port, IP, _}) ->
                              {Port, IP, T};
                         (_, Res) ->
                              Res
                      end, {5222, {0,0,0,0}, tcp}, Val)
            end;
       is_tuple(Val) ->
            element(1, Val);
       true ->
            Val
    end.

maps_to_lists(IMap) ->
    maps:fold(fun(Name, Map, Res) when Name == host_config orelse Name == append_host_config ->
                      [{Name, [{Host, maps_to_lists(SMap)} || {Host,SMap} <- maps:values(Map)]} | Res];
                 (Name, Map, Res) when is_map(Map) ->
                      [{Name, maps:values(Map)} | Res];
                 (Name, Val, Res) ->
                      [{Name, Val} | Res]
              end, [], IMap).

merge_configs(Terms, ResMap) ->
    lists:foldl(fun({Name, Val}, Map) when is_list(Val), Name =/= auth_method ->
                        Old = maps:get(Name, Map, #{}),
                        New = lists:foldl(fun(SVal, OMap) ->
                                                  NVal = if Name == host_config orelse Name == append_host_config ->
                                                                 {Host, Opts} = SVal,
                                                                 {_, SubMap} = maps:get(Host, OMap, {Host, #{}}),
                                                                 {Host, merge_configs(Opts, SubMap)};
                                                            true ->
                                                                 SVal
                                                         end,
                                                  maps:put(get_config_option_key(Name, SVal), NVal, OMap)
                                          end, Old, Val),
                        maps:put(Name, New, Map);
                   ({Name, Val}, Map) ->
                        maps:put(Name, Val, Map)
                end, ResMap, Terms).

%% @doc Include additional configuration files in the list of terms.
%% @spec ([term()]) -> [term()]
include_config_files(Terms) ->
    {FileOpts, Terms1} =
        lists:mapfoldl(
          fun({include_config_file, _} = T, Ts) ->
                  {[transform_include_option(T)], Ts};
             ({include_config_file, _, _} = T, Ts) ->
                  {[transform_include_option(T)], Ts};
             (T, Ts) ->
                  {[], [T|Ts]}
          end, [], Terms),
    Terms2 = lists:flatmap(
               fun({File, Opts}) ->
                       include_config_file(File, Opts)
               end, lists:flatten(FileOpts)),

    M1 = merge_configs(Terms1, #{}),
    M2 = merge_configs(Terms2, M1),
    maps_to_lists(M2).

transform_include_option({include_config_file, File}) when is_list(File) ->
    case is_string(File) of
        true -> {File, []};
        false -> File
    end;
transform_include_option({include_config_file, Filename}) ->
    {Filename, []};
transform_include_option({include_config_file, Filename, Options}) ->
    {Filename, Options}.

include_config_file(Filename, Options) ->
    Included_terms = get_plain_terms_file(Filename, [{include_files, true}, dont_halt_on_error]),
    Disallow = proplists:get_value(disallow, Options, []),
    Included_terms2 = delete_disallowed(Disallow, Included_terms),
    Allow_only = proplists:get_value(allow_only, Options, all),
    keep_only_allowed(Allow_only, Included_terms2).

%% @doc Filter from the list of terms the disallowed.
%% Returns a sublist of Terms without the ones which first element is
%% included in Disallowed.
%% @spec (Disallowed::[atom()], Terms::[term()]) -> [term()]
delete_disallowed(Disallowed, Terms) ->
    lists:foldl(
      fun(Dis, Ldis) ->
	      delete_disallowed2(Dis, Ldis)
      end,
      Terms,
      Disallowed).

delete_disallowed2(Disallowed, [H|T]) ->
    case element(1, H) of
	Disallowed ->
	    ?WARNING_MSG("The option '~p' is disallowed, "
			 "and will not be accepted", [Disallowed]),
	    delete_disallowed2(Disallowed, T);
	_ ->
	    [H|delete_disallowed2(Disallowed, T)]
    end;
delete_disallowed2(_, []) ->
    [].

%% @doc Keep from the list only the allowed terms.
%% Returns a sublist of Terms with only the ones which first element is
%% included in Allowed.
%% @spec (Allowed::[atom()], Terms::[term()]) -> [term()]
keep_only_allowed(all, Terms) ->
    Terms;
keep_only_allowed(Allowed, Terms) ->
    {As, NAs} = lists:partition(
		  fun(Term) ->
			  lists:member(element(1, Term), Allowed)
		  end,
		  Terms),
    [?WARNING_MSG("This option is not allowed, "
		  "and will not be accepted:~n~p", [NA])
     || NA <- NAs],
    As.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Support for Macro

%% @doc Replace the macros with their defined values.
%% @spec (Terms::[term()]) -> [term()]
replace_macros(Terms) ->
    {TermsOthers, Macros} = split_terms_macros(Terms),
    replace(TermsOthers, Macros).

%% @doc Split Terms into normal terms and macro definitions.
%% @spec (Terms) -> {Terms, Macros}
%%       Terms = [term()]
%%       Macros = [macro()]
split_terms_macros(Terms) ->
    lists:foldl(
      fun(Term, {TOs, Ms}) ->
	      case Term of
		  {define_macro, Key, Value} ->
		      case is_correct_macro({Key, Value}) of
			  true ->
			      {TOs, Ms++[{Key, Value}]};
			  false ->
			      exit({macro_not_properly_defined, Term})
		      end;
                  {define_macro, KeyVals} ->
                      case lists:all(fun is_correct_macro/1, KeyVals) of
                          true ->
                              {TOs, Ms ++ KeyVals};
                          false ->
                              exit({macros_not_properly_defined, Term})
                      end;
		  Term ->
		      {TOs ++ [Term], Ms}
	      end
      end,
      {[], []},
      Terms).

is_correct_macro({Key, _Val}) ->
    is_atom(Key) and is_all_uppercase(Key);
is_correct_macro(_) ->
    false.

%% @doc Recursively replace in Terms macro usages with the defined value.
%% @spec (Terms, Macros) -> Terms
%%       Terms = [term()]
%%       Macros = [macro()]
replace([], _) ->
    [];
replace([Term|Terms], Macros) ->
    [replace_term(Term, Macros) | replace(Terms, Macros)];
replace(Term, Macros) ->
    replace_term(Term, Macros).

replace_term(Key, Macros) when is_atom(Key) ->
    case is_all_uppercase(Key) of
	true ->
	    case proplists:get_value(Key, Macros) of
		undefined -> exit({undefined_macro, Key});
		Value -> Value
	    end;
	false ->
	    Key
    end;
replace_term({use_macro, Key, Value}, Macros) ->
    proplists:get_value(Key, Macros, Value);
replace_term(Term, Macros) when is_list(Term) ->
    replace(Term, Macros);
replace_term(Term, Macros) when is_tuple(Term) ->
    List = tuple_to_list(Term),
    List2 = replace(List, Macros),
    list_to_tuple(List2);
replace_term(Term, _) ->
    Term.

is_all_uppercase(Atom) ->
    String = erlang:atom_to_list(Atom),
    lists:all(fun(C) when C >= $a, C =< $z -> false;
		 (_) -> true
	      end, String).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Process terms

process_term(Term, State) ->
    case Term of
	{host_config, HostTerms} ->
            lists:foldl(
              fun({Host, Terms}, AccState) ->
                      lists:foldl(fun(T, S) ->
                                          process_host_term(T, Host, S, set)
                                  end, AccState, Terms)
              end, State, HostTerms);
        {append_host_config, HostTerms} ->
            lists:foldl(
              fun({Host, Terms}, AccState) ->
                      lists:foldl(fun(T, S) ->
                                          process_host_term(T, Host, S, append)
                                  end, AccState, Terms)
              end, State, HostTerms);
	_ ->
            process_host_term(Term, global, State, set)
    end.

process_host_term(Term, Host, State, Action) ->
    case Term of
        {modules, Modules} when Action == set ->
            set_option({modules, Host}, replace_modules(Modules), State);
        {modules, Modules} when Action == append ->
            append_option({modules, Host}, replace_modules(Modules), State);
        {host, _} ->
            State;
        {hosts, _} ->
            State;
	{Opt, Val} when Action == set ->
	    set_option({rename_option(Opt), Host}, change_val(Opt, Val), State);
        {Opt, Val} when Action == append ->
            append_option({rename_option(Opt), Host}, change_val(Opt, Val), State);
        Opt ->
            ?WARNING_MSG("Ignore invalid (outdated?) option ~p", [Opt]),
            State
    end.

rename_option(Option) when is_atom(Option) ->
    case atom_to_list(Option) of
	"odbc_" ++ T ->
	    NewOption = list_to_atom("sql_" ++ T),
	    ?WARNING_MSG("Option '~s' is obsoleted, use '~s' instead",
			 [Option, NewOption]),
	    NewOption;
	_ ->
	    Option
    end;
rename_option(Option) ->
    Option.

change_val(auth_method, Val) ->
    prepare_opt_val(auth_method, Val,
		    fun(V) ->
			    L = if is_list(V) -> V;
				   true -> [V]
				end,
			    lists:map(
			      fun(odbc) -> sql;
				 (internal) -> mnesia;
				 (A) when is_atom(A) -> A
			      end, L)
		    end, [mnesia]);
change_val(_Opt, Val) ->
    Val.

set_option(Opt, Val, State) ->
    State#state{opts = [#local_config{key = Opt, value = Val} |
                        State#state.opts]}.

append_option({Opt, Host}, Val, State) ->
    GlobalVals = lists:flatmap(
                   fun(#local_config{key = {O, global}, value = V})
                         when O == Opt ->
                           if is_list(V) -> V;
                              true -> [V]
                           end;
                      (_) ->
                           []
                   end, State#state.opts),
    NewVal = if is_list(Val) -> Val ++ GlobalVals;
                true -> [Val|GlobalVals]
             end,
    set_option({Opt, Host}, NewVal, State).

set_opts(State) ->
    Opts = State#state.opts,
    ets:insert(
      ejabberd_options,
      lists:map(
	fun(#local_config{key = Key, value = Val}) ->
		{Key, Val}
	end, Opts)),
    set_fqdn(),
    set_log_level().

set_fqdn() ->
    FQDNs = case get_option(fqdn, []) of
		[] ->
		    {ok, Hostname} = inet:gethostname(),
		    case inet:gethostbyname(Hostname) of
			{ok, #hostent{h_name = FQDN}} ->
			    [iolist_to_binary(FQDN)];
			{error, _} ->
			    []
		    end;
		Domains ->
		    Domains
	      end,
    xmpp:set_config([{fqdn, FQDNs}]).

set_log_level() ->
    Level = get_option(loglevel, 4),
    ejabberd_logger:set(Level).

add_global_option(Opt, Val) ->
    add_option(Opt, Val).

add_local_option(Opt, Val) ->
    add_option(Opt, Val).

add_option(Opt, Val) when is_atom(Opt) ->
    add_option({Opt, global}, Val);
add_option({Opt, Host}, Val) ->
    ets:insert(ejabberd_options, {{Opt, Host}, Val}),
    ok.

-spec prepare_opt_val(any(), any(), check_fun(), any()) -> any().

prepare_opt_val(Opt, Val, F, Default) ->
    Call = case F of
	       {Mod, Fun} ->
		   fun() -> Mod:Fun(Val) end;
	       _ ->
		   fun() -> F(Val) end
	   end,
    try Call() of
	Res ->
	    Res
    catch {replace_with, NewRes} ->
	    NewRes;
	  {invalid_syntax, Error} ->
	    ?WARNING_MSG("incorrect value '~s' of option '~s', "
			 "using '~s' as fallback: ~s",
			 [format_term(Val),
			  format_term(Opt),
			  format_term(Default),
			  Error]),
	    Default;
	  _:_ ->
	    ?WARNING_MSG("incorrect value '~s' of option '~s', "
			 "using '~s' as fallback",
			 [format_term(Val),
			  format_term(Opt),
			  format_term(Default)]),
	    Default
    end.

-type check_fun() :: fun((any()) -> any()) | {module(), atom()}.

-spec get_global_option(any(), check_fun()) -> any().

get_global_option(Opt, _) ->
    get_option(Opt, undefined).

-spec get_global_option(any(), check_fun(), any()) -> any().

get_global_option(Opt, _, Default) ->
    get_option(Opt, Default).

-spec get_local_option(any(), check_fun()) -> any().

get_local_option(Opt, _) ->
    get_option(Opt, undefined).

-spec get_local_option(any(), check_fun(), any()) -> any().

get_local_option(Opt, _, Default) ->
    get_option(Opt, Default).

-spec get_option(any()) -> any().
get_option(Opt) ->
    get_option(Opt, undefined).

-spec get_option(any(), check_fun(), any()) -> any().
get_option(Opt, _, Default) ->
    get_option(Opt, Default).

-spec get_option(any(), check_fun() | any()) -> any().
get_option(Opt, F) when is_function(F) ->
    get_option(Opt, undefined);
get_option(Opt, Default) when is_atom(Opt) ->
    get_option({Opt, global}, Default);
get_option(Opt, Default) ->
    {Key, Host} = case Opt of
		      {O, global} when is_atom(O) -> Opt;
		      {O, H} when is_atom(O), is_binary(H) -> Opt;
		      _ ->
			  ?WARNING_MSG("Option ~p has invalid (outdated?) "
				       "format. This is likely a bug", [Opt]),
			  {undefined, global}
		  end,
    try ets:lookup_element(ejabberd_options, {Key, Host}, 2)
    catch _:badarg when Host /= global ->
	    try ets:lookup_element(ejabberd_options, {Key, global}, 2)
	    catch _:badarg -> Default
	    end;
	  _:badarg ->
	    Default
    end.

-spec has_option(atom() | {atom(), global | binary()}) -> any().
has_option(Opt) ->
    get_option(Opt) /= undefined.

init_module_db_table(Modules) ->
    %% Dirty hack for mod_pubsub
    ets:insert(ejabberd_db_modules, {{mod_pubsub, mnesia}, true}),
    ets:insert(ejabberd_db_modules, {{mod_pubsub, sql}, true}),
    lists:foreach(
      fun(M) ->
	      case re:split(atom_to_list(M), "_", [{return, list}]) of
		  [_] ->
		      ok;
		  Parts ->
		      [H|T] = lists:reverse(Parts),
		      Suffix = list_to_atom(H),
		      BareMod = list_to_atom(string:join(lists:reverse(T), "_")),
		      case is_behaviour(BareMod, M) of
			  true ->
			      ets:insert(ejabberd_db_modules,
					 {{BareMod, Suffix}, true});
			  false ->
			      ok
		      end
	      end
      end, Modules).

is_behaviour(Behav, Mod) ->
    try Mod:module_info(attributes) of
	[] ->
	    %% Stripped module?
	    true;
	Attrs ->
	    lists:any(
	      fun({behaviour, L}) -> lists:member(Behav, L);
		 ({behavior, L}) -> lists:member(Behav, L);
		 (_) -> false
	      end, Attrs)
    catch _:_ ->
	    true
    end.

-spec v_db(module(), atom()) -> atom().

v_db(Mod, internal) -> v_db(Mod, mnesia);
v_db(Mod, odbc) -> v_db(Mod, sql);
v_db(Mod, Type) ->
    case ets:member(ejabberd_db_modules, {Mod, Type}) of
	true -> Type;
	false -> erlang:error(badarg)
    end.

-spec v_dbs(module()) -> [atom()].

v_dbs(Mod) ->
    ets:select(
      ejabberd_db_modules,
      ets:fun2ms(
	fun({{M, Type}, _}) when M == Mod ->
		Type
	end)).

-spec v_dbs_mods(module()) -> [module()].

v_dbs_mods(Mod) ->
    lists:map(fun(M) ->
		      binary_to_atom(<<(atom_to_binary(Mod, utf8))/binary, "_",
				       (atom_to_binary(M, utf8))/binary>>, utf8)
	      end, v_dbs(Mod)).

-spec v_host(binary()) -> binary().
v_host(Host) ->
    hd(v_hosts([Host])).

-spec v_hosts([binary()]) -> [binary()].
v_hosts(Hosts) ->
    ServerHosts = get_myhosts(),
    lists:foldr(
      fun(Host, Acc) ->
	      case lists:member(Host, ServerHosts) of
		  true ->
		      ?ERROR_MSG("Failed to reuse route ~s because it's "
				 "already registered on a virtual host",
				 [Host]),
		      erlang:error(badarg);
		  false ->
		      case lists:member(Host, Acc) of
			  true ->
			      ?ERROR_MSG("Host ~s is defined multiple times",
					 [Host]),
			      erlang:error(badarg);
			  false ->
			      [Host|Acc]
		      end
	      end
      end, [], Hosts).

-spec default_db(module()) -> atom().
default_db(Module) ->
    default_db(global, Module).

-spec default_db(binary() | global, module()) -> atom().
default_db(Host, Module) ->
    default_db(default_db, Host, Module).

-spec default_ram_db(module()) -> atom().
default_ram_db(Module) ->
    default_ram_db(global, Module).

-spec default_ram_db(binary() | global, module()) -> atom().
default_ram_db(Host, Module) ->
    default_db(default_ram_db, Host, Module).

-spec default_db(default_db | default_ram_db, binary() | global, module()) -> atom().
default_db(Opt, Host, Module) ->
    case get_option({Opt, Host}) of
	undefined ->
	    mnesia;
	DBType ->
	    try
		v_db(Module, DBType)
	    catch error:badarg ->
		    ?WARNING_MSG("Module '~s' doesn't support database '~s' "
				 "defined in option '~s', using "
				 "'mnesia' as fallback", [Module, DBType, Opt]),
		    mnesia
	    end
    end.

get_modules() ->
    {ok, Mods} = application:get_key(ejabberd, modules),
    ExtMods = [Name || {Name, _Details} <- ext_mod:installed()],
    case application:get_env(ejabberd, external_beams) of
	{ok, Path} ->
	    case lists:member(Path, code:get_path()) of
		true -> ok;
		false -> code:add_patha(Path)
	    end,
	    Beams = filelib:wildcard(filename:join(Path, "*\.beam")),
	    CustMods = [list_to_atom(filename:rootname(filename:basename(Beam)))
			|| Beam <- Beams],
	    CustMods ++ ExtMods ++ Mods;
	_ ->
	    ExtMods ++ Mods
    end.

get_modules_with_options(Modules) ->
    lists:foldl(
      fun(Mod, D) ->
	      case is_behaviour(?MODULE, Mod) orelse Mod == ?MODULE of
		  true ->
		      try Mod:opt_type('') of
			  Opts when is_list(Opts) ->
			      lists:foldl(
				fun(Opt, Acc) ->
					dict:append(Opt, Mod, Acc)
				end, D, Opts)
		      catch _:undef ->
			      D
		      end;
		  false ->
		      D
	      end
      end, dict:new(), Modules).

-spec validate_opts(#state{}, dict:dict()) -> {ok, #state{}} | {error, bad_option()}.
validate_opts(#state{opts = Opts} = State, ModOpts) ->
    try
	NewOpts = lists:map(
		    fun(#local_config{key = {Opt, _Host}, value = Val} = In) ->
			    case dict:find(Opt, ModOpts) of
				{ok, [Mod|_]} ->
				    VFun = Mod:opt_type(Opt),
				    try VFun(Val) of
					NewVal ->
					    In#local_config{value = NewVal}
				    catch {invalid_syntax, Error} ->
					    ?ERROR_MSG("Invalid value for "
						       "option '~s' (~s): ~s",
						       [Opt, Error,
							misc:format_val({yaml, Val})]),
					    erlang:error(invalid_option);
					  _:R when R /= undef ->
					    ?ERROR_MSG("Invalid value for "
						       "option '~s': ~s",
						       [Opt, misc:format_val({yaml, Val})]),
					    erlang:error(invalid_option)
				    end;
				_ ->
				    ?ERROR_MSG("Unknown option '~s'", [Opt]),
				    erlang:error(unknown_option)
			    end
		    end, Opts),
	{ok, State#state{opts = NewOpts}}
    catch _:invalid_option ->
	    {error, invalid_option};
	  _:unknown_option ->
	    {error, unknown_option}
    end.

%% @spec (Path::string()) -> true | false
is_file_readable(Path) ->
    case file:read_file_info(Path) of
	{ok, FileInfo} ->
	    case {FileInfo#file_info.type, FileInfo#file_info.access} of
		{regular, read} -> true;
		{regular, read_write} -> true;
		_ -> false
	    end;
	{error, _Reason} ->
	    false
    end.

get_version() ->
    case application:get_env(ejabberd, custom_vsn) of
	{ok, Vsn0} when is_list(Vsn0) ->
	    list_to_binary(Vsn0);
	{ok, Vsn1} when is_binary(Vsn1) ->
	    Vsn1;
	_ ->
	    case application:get_key(ejabberd, vsn) of
		undefined -> "";
		{ok, Vsn} -> list_to_binary(Vsn)
	    end
    end.

-spec get_myhosts() -> [binary()].

get_myhosts() ->
    get_option(hosts, [<<"localhost">>]).

-spec get_myname() -> binary().

get_myname() ->
    hd(get_myhosts()).

-spec get_mylang() -> binary().

get_mylang() ->
    get_lang(global).

-spec get_lang(global | binary()) -> binary().
get_lang(Host) ->
    get_option({language, Host}, <<"en">>).

-spec get_uri() -> binary().
get_uri() ->
    <<"http://www.process-one.net/en/ejabberd/">>.

-spec get_copyright() -> binary().
get_copyright() ->
    <<"Copyright (c) ProcessOne">>.

replace_module(mod_announce_odbc) -> {mod_announce, sql};
replace_module(mod_blocking_odbc) -> {mod_blocking, sql};
replace_module(mod_caps_odbc) -> {mod_caps, sql};
replace_module(mod_last_odbc) -> {mod_last, sql};
replace_module(mod_muc_odbc) -> {mod_muc, sql};
replace_module(mod_offline_odbc) -> {mod_offline, sql};
replace_module(mod_privacy_odbc) -> {mod_privacy, sql};
replace_module(mod_private_odbc) -> {mod_private, sql};
replace_module(mod_roster_odbc) -> {mod_roster, sql};
replace_module(mod_shared_roster_odbc) -> {mod_shared_roster, sql};
replace_module(mod_vcard_odbc) -> {mod_vcard, sql};
replace_module(mod_vcard_ldap) -> {mod_vcard, ldap};
replace_module(mod_vcard_xupdate_odbc) -> mod_vcard_xupdate;
replace_module(mod_pubsub_odbc) -> {mod_pubsub, sql};
replace_module(mod_http_bind) -> mod_bosh;
replace_module(Module) ->
    case is_elixir_module(Module) of
        true  -> expand_elixir_module(Module);
        false -> Module
    end.

replace_modules(Modules) ->
    lists:map(
        fun({Module, Opts}) ->
                case replace_module(Module) of
                    {NewModule, DBType} ->
                        emit_deprecation_warning(Module, NewModule, DBType),
                        NewOpts = [{db_type, DBType} |
                                   lists:keydelete(db_type, 1, Opts)],
                        {NewModule, transform_module_options(Module, NewOpts)};
                    NewModule ->
                        if Module /= NewModule ->
                                emit_deprecation_warning(Module, NewModule);
                           true ->
                                ok
                        end,
                        {NewModule, transform_module_options(Module, Opts)}
                end
        end, Modules).

%% Elixir module naming
%% ====================

-ifdef(ELIXIR_ENABLED).
is_elixir_enabled() ->
    true.
-else.
is_elixir_enabled() ->
    false.
-endif.

is_using_elixir_config() ->
    case is_elixir_enabled() of
	true ->
	    Config = get_ejabberd_config_path(),
	    'Elixir.Ejabberd.ConfigUtil':is_elixir_config(Config);
       false ->
	    false
    end.

%% If module name start with uppercase letter, this is an Elixir module:
is_elixir_module(Module) ->
    case atom_to_list(Module) of
        [H|_] when H >= 65, H =< 90 -> true;
        _ ->false
    end.

%% We assume we know this is an elixir module
expand_elixir_module(Module) ->
    case atom_to_list(Module) of
        %% Module name already specified as an Elixir from Erlang module name
        "Elixir." ++ _ -> Module;
        %% if start with uppercase letter, this is an Elixir module: Append 'Elixir.' to module name.
        ModuleString ->
            list_to_atom("Elixir." ++ ModuleString)
    end.

strings_to_binary([]) ->
    [];
strings_to_binary(L) when is_list(L) ->
    case is_string(L) of
        true ->
            list_to_binary(L);
        false ->
            strings_to_binary1(L)
    end;
strings_to_binary({A, B, C, D}) when
	is_integer(A), is_integer(B), is_integer(C), is_integer(D) ->
    {A, B, C ,D};
strings_to_binary(T) when is_tuple(T) ->
    list_to_tuple(strings_to_binary1(tuple_to_list(T)));
strings_to_binary(X) ->
    X.

strings_to_binary1([El|L]) ->
    [strings_to_binary(El)|strings_to_binary1(L)];
strings_to_binary1([]) ->
    [];
strings_to_binary1(T) ->
    T.

is_string([C|T]) when (C >= 0) and (C =< 255) ->
    is_string(T);
is_string([]) ->
    true;
is_string(_) ->
    false.

binary_to_strings(B) when is_binary(B) ->
    binary_to_list(B);
binary_to_strings([H|T]) ->
    [binary_to_strings(H)|binary_to_strings(T)];
binary_to_strings(T) when is_tuple(T) ->
    list_to_tuple(binary_to_strings(tuple_to_list(T)));
binary_to_strings(T) ->
    T.

format_term(Bin) when is_binary(Bin) ->
    io_lib:format("\"~s\"", [Bin]);
format_term(S) when is_list(S), S /= [] ->
    case lists:all(fun(C) -> (C>=0) and (C=<255) end, S) of
        true ->
            io_lib:format("\"~s\"", [S]);
        false ->
            io_lib:format("~p", [binary_to_strings(S)])
    end;
format_term(T) ->
    io_lib:format("~p", [binary_to_strings(T)]).

transform_terms(Terms) ->
    %% We could check all ejabberd beams, but this
    %% slows down start-up procedure :(
    Mods = [mod_register,
            ejabberd_s2s,
            ejabberd_listener,
            ejabberd_sql_sup,
            ejabberd_shaper,
            ejabberd_s2s_out,
            acl,
            ejabberd_config],
    collect_options(transform_terms(Mods, Terms)).

transform_terms([Mod|Mods], Terms) ->
    case catch Mod:transform_options(Terms) of
        {'EXIT', _} = Err ->
            ?ERROR_MSG("Failed to transform terms by ~p: ~p", [Mod, Err]),
            transform_terms(Mods, Terms);
        NewTerms ->
            transform_terms(Mods, NewTerms)
    end;
transform_terms([], NewTerms) ->
    NewTerms.

transform_module_options(Module, Opts) ->
    Opts1 = gen_iq_handler:transform_module_options(Opts),
    try
        Module:transform_module_options(Opts1)
    catch error:undef ->
            Opts1
    end.

compact(Cfg) ->
    Opts = [{K, V} || #local_config{key = K, value = V} <- Cfg],
    {GOpts, HOpts} = split_by_hosts(Opts),
    [#local_config{key = {O, global}, value = V} || {O, V} <- GOpts] ++
        lists:flatmap(
          fun({Host, OptVal}) ->
                  case lists:member(OptVal, GOpts) of
                      true ->
                          [];
                      false ->
                          [#local_config{key = {Opt, Host}, value = Val}
                           || {Opt, Val} <- OptVal]
                  end
          end, lists:flatten(HOpts)).

split_by_hosts(Opts) ->
    Opts1 = orddict:to_list(
              lists:foldl(
                fun({{Opt, Host}, Val}, D) ->
                        orddict:append(Host, {Opt, Val}, D)
                end, orddict:new(), Opts)),
    case lists:keytake(global, 1, Opts1) of
        {value, {global, GlobalOpts}, HostOpts} ->
            {GlobalOpts, HostOpts};
        _ ->
            {[], Opts1}
    end.

collect_options(Opts) ->
    {D, InvalidOpts} =
        lists:foldl(
          fun({K, V}, {D, Os}) when is_list(V) ->
                  {orddict:append_list(K, V, D), Os};
             ({K, V}, {D, Os}) ->
                  {orddict:store(K, V, D), Os};
             (Opt, {D, Os}) ->
                  {D, [Opt|Os]}
          end, {orddict:new(), []}, Opts),
    InvalidOpts ++ orddict:to_list(D).

transform_options(Opts) ->
    Opts1 = lists:foldl(fun transform_options/2, [], Opts),
    {HOpts, Opts2} = lists:mapfoldl(
                       fun({host_config, O}, Os) ->
                               {[O], Os};
                          (O, Os) ->
                               {[], [O|Os]}
                       end, [], Opts1),
    {AHOpts, Opts3} = lists:mapfoldl(
                        fun({append_host_config, O}, Os) ->
                                {[O], Os};
                           (O, Os) ->
                                {[], [O|Os]}
                        end, [], Opts2),
    HOpts1 = case collect_options(lists:flatten(HOpts)) of
                 [] ->
                     [];
                 HOs ->
                     [{host_config,
                       [{H, transform_terms(O)} || {H, O} <- HOs]}]
             end,
    AHOpts1 = case collect_options(lists:flatten(AHOpts)) of
                  [] ->
                      [];
                  AHOs ->
                      [{append_host_config,
                        [{H, transform_terms(O)} || {H, O} <- AHOs]}]
              end,
    HOpts1 ++ AHOpts1 ++ Opts3.

transform_options({domain_certfile, Domain, CertFile}, Opts) ->
    ?WARNING_MSG("Option 'domain_certfile' now should be defined "
                 "per virtual host or globally. The old format is "
                 "still supported but it is better to fix your config", []),
    [{host_config, [{Domain, [{domain_certfile, CertFile}]}]}|Opts];
transform_options(Opt, Opts) when Opt == override_global;
                                  Opt == override_local;
                                  Opt == override_acls ->
    ?WARNING_MSG("Ignoring '~s' option which has no effect anymore", [Opt]),
    Opts;
transform_options({node_start, {_, _, _} = Now}, Opts) ->
    ?WARNING_MSG("Old 'node_start' format detected. This is still supported "
                 "but it is better to fix your config.", []),
    [{node_start, now_to_seconds(Now)}|Opts];
transform_options({host_config, Host, HOpts}, Opts) ->
    {AddOpts, HOpts1} =
        lists:mapfoldl(
          fun({{add, Opt}, Val}, Os) ->
                  ?WARNING_MSG("Option 'add' is deprecated. "
                               "The option is still supported "
                               "but it is better to fix your config: "
                               "use 'append_host_config' instead.", []),
                  {[{Opt, Val}], Os};
             (O, Os) ->
                  {[], [O|Os]}
          end, [], HOpts),
    [{append_host_config, [{Host, lists:flatten(AddOpts)}]},
     {host_config, [{Host, HOpts1}]}|Opts];
transform_options({define_macro, Macro, Val}, Opts) ->
    [{define_macro, [{Macro, Val}]}|Opts];
transform_options({include_config_file, _} = Opt, Opts) ->
    [{include_config_file, [transform_include_option(Opt)]} | Opts];
transform_options({include_config_file, _, _} = Opt, Opts) ->
    [{include_config_file, [transform_include_option(Opt)]} | Opts];
transform_options(Opt, Opts) ->
    [Opt|Opts].

emit_deprecation_warning(Module, NewModule, DBType) ->
    ?WARNING_MSG("Module ~s is deprecated, use ~s with 'db_type: ~s'"
                 " instead", [Module, NewModule, DBType]).

emit_deprecation_warning(Module, NewModule) ->
    case is_elixir_module(NewModule) of
        %% Do not emit deprecation warning for Elixir
        true -> ok;
        false ->
            ?WARNING_MSG("Module ~s is deprecated, use ~s instead",
                         [Module, NewModule])
    end.

-spec now_to_seconds(erlang:timestamp()) -> non_neg_integer().
now_to_seconds({MegaSecs, Secs, _MicroSecs}) ->
    MegaSecs * 1000000 + Secs.

-spec opt_type(atom()) -> fun((any()) -> any()) | [atom()].
opt_type(hide_sensitive_log_data) ->
    fun (H) when is_boolean(H) -> H end;
opt_type(hosts) ->
    fun(L) ->
	    [iolist_to_binary(H) || H <- L]
    end;
opt_type(language) ->
    fun iolist_to_binary/1;
opt_type(max_fsm_queue) ->
    fun (I) when is_integer(I), I > 0 -> I end;
opt_type(default_db) ->
    fun(T) when is_atom(T) -> T end;
opt_type(default_ram_db) ->
    fun(T) when is_atom(T) -> T end;
opt_type(loglevel) ->
    fun (P) when P >= 0, P =< 5 -> P end;
opt_type(queue_dir) ->
    fun iolist_to_binary/1;
opt_type(queue_type) ->
    fun(ram) -> ram; (file) -> file end;
opt_type(use_cache) ->
    fun(B) when is_boolean(B) -> B end;
opt_type(cache_size) ->
    fun(I) when is_integer(I), I>0 -> I;
       (infinity) -> infinity;
       (unlimited) -> infinity
    end;
opt_type(cache_missed) ->
    fun(B) when is_boolean(B) -> B end;
opt_type(cache_life_time) ->
    fun(I) when is_integer(I), I>0 -> I;
       (infinity) -> infinity;
       (unlimited) -> infinity
    end;
opt_type(negotiation_timeout) ->
    fun(T) when T > 0 -> T end;
opt_type(shared_key) ->
    fun iolist_to_binary/1;
opt_type(node_start) ->
    fun(I) when is_integer(I), I>=0 -> I end;
opt_type(validate_stream) ->
    fun(B) when is_boolean(B) -> B end;
opt_type(fqdn) ->
    fun(Domain) when is_binary(Domain) ->
	    [Domain];
       (Domains) ->
	    [iolist_to_binary(Domain) || Domain <- Domains]
    end;
opt_type(_) ->
    [hide_sensitive_log_data, hosts, language, max_fsm_queue,
     default_db, default_ram_db, queue_type, queue_dir, loglevel,
     use_cache, cache_size, cache_missed, cache_life_time, fqdn,
     shared_key, node_start, validate_stream, negotiation_timeout].

-spec may_hide_data(any()) -> any().
may_hide_data(Data) ->
    case get_option(hide_sensitive_log_data, false) of
	false ->
	    Data;
	true ->
	    "hidden_by_ejabberd"
    end.

-spec fsm_limit_opts([proplists:property()]) -> [{max_queue, pos_integer()}].
fsm_limit_opts(Opts) ->
    case lists:keyfind(max_fsm_queue, 1, Opts) of
	{_, I} when is_integer(I), I>0 ->
	    [{max_queue, I}];
	false ->
	    case get_option(max_fsm_queue) of
		undefined -> [];
		N -> [{max_queue, N}]
	    end
    end.

-spec queue_dir() -> binary() | undefined.
queue_dir() ->
    get_option(queue_dir).

-spec default_queue_type(binary()) -> ram | file.
default_queue_type(Host) ->
    get_option({queue_type, Host}, ram).

-spec use_cache(binary() | global) -> boolean().
use_cache(Host) ->
    get_option({use_cache, Host}, true).

-spec cache_size(binary() | global) -> pos_integer() | infinity.
cache_size(Host) ->
    get_option({cache_size, Host}, 1000).

-spec cache_missed(binary() | global) -> boolean().
cache_missed(Host) ->
    get_option({cache_missed, Host}, true).

-spec cache_life_time(binary() | global) -> pos_integer() | infinity.
%% NOTE: the integer value returned is in *seconds*
cache_life_time(Host) ->
    get_option({cache_life_time, Host}, 3600).

-spec codec_options(binary() | global) -> [xmpp:decode_option()].
codec_options(Host) ->
    case get_option({validate_stream, Host}, false) of
	true -> [];
	false -> [ignore_els]
    end.

-spec negotiation_timeout() -> pos_integer().
negotiation_timeout() ->
    timer:seconds(get_option(negotiation_timeout, 30)).
