%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2011-2013 GoPivotal, Inc.  All rights reserved.
%%

-module(rabbit_plugins_main).
-include("rabbit.hrl").

-export([start/0, stop/0]).

-define(NODE_OPT, "-n").
-define(VERBOSE_OPT, "-v").
-define(MINIMAL_OPT, "-m").
-define(ENABLED_OPT, "-E").
-define(ENABLED_ALL_OPT, "-e").

-define(NODE_DEF(Node), {?NODE_OPT, {option, Node}}).
-define(VERBOSE_DEF, {?VERBOSE_OPT, flag}).
-define(MINIMAL_DEF, {?MINIMAL_OPT, flag}).
-define(ENABLED_DEF, {?ENABLED_OPT, flag}).
-define(ENABLED_ALL_DEF, {?ENABLED_ALL_OPT, flag}).

-define(RPC_TIMEOUT, infinity).

-define(GLOBAL_DEFS(Node), [?NODE_DEF(Node)]).

-define(COMMANDS,
        [{list, [?VERBOSE_DEF, ?MINIMAL_DEF, ?ENABLED_DEF, ?ENABLED_ALL_DEF]},
         enable,
         disable]).

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-spec(start/0 :: () -> no_return()).
-spec(stop/0 :: () -> 'ok').
-spec(usage/0 :: () -> no_return()).

-endif.

%%----------------------------------------------------------------------------

start() ->
    {ok, [[PluginsFile|_]|_]} =
        init:get_argument(enabled_plugins_file),
    {ok, [[NodeStr|_]|_]} = init:get_argument(nodename),
    {ok, [[PluginsDir|_]|_]} = init:get_argument(plugins_dist_dir),
    {Command, Opts, Args} =
        case parse_arguments(init:get_plain_arguments(), NodeStr) of
            {ok, Res}  -> Res;
            no_command -> print_error("could not recognise command", []),
                          usage()
        end,

    PrintInvalidCommandError =
        fun () ->
                print_error("invalid command '~s'",
                            [string:join([atom_to_list(Command) | Args], " ")])
        end,

    Node = proplists:get_value(?NODE_OPT, Opts),
    case catch action(Command, Node, Args, Opts, PluginsFile, PluginsDir) of
        ok ->
            rabbit_misc:quit(0);
        {'EXIT', {function_clause, [{?MODULE, action, _} | _]}} ->
            PrintInvalidCommandError(),
            usage();
        {'EXIT', {function_clause, [{?MODULE, action, _, _} | _]}} ->
            PrintInvalidCommandError(),
            usage();
        {error, Reason} ->
            print_error("~p", [Reason]),
            rabbit_misc:quit(2);
        {error_string, Reason} ->
            print_error("~s", [Reason]),
            rabbit_misc:quit(2);
        Other ->
            print_error("~p", [Other]),
            rabbit_misc:quit(2)
    end.

stop() ->
    ok.

%%----------------------------------------------------------------------------

parse_arguments(CmdLine, NodeStr) ->
    case rabbit_misc:parse_arguments(
           ?COMMANDS, ?GLOBAL_DEFS(NodeStr), CmdLine) of
        {ok, {Cmd, Opts0, Args}} ->
            Opts = [case K of
                        ?NODE_OPT -> {?NODE_OPT, rabbit_nodes:make(V)};
                        _         -> {K, V}
                    end || {K, V} <- Opts0],
            {ok, {Cmd, Opts, Args}};
        E ->
            E
    end.

action(list, Node, [], Opts, PluginsFile, PluginsDir) ->
    action(list, Node, [".*"], Opts, PluginsFile, PluginsDir);
action(list, _Node, [Pat], Opts, PluginsFile, PluginsDir) ->
    format_plugins(Pat, Opts, PluginsFile, PluginsDir);

action(enable, Node, ToEnable0, _Opts, PluginsFile, PluginsDir) ->
    case ToEnable0 of
        [] -> throw({error_string, "Not enough arguments for 'enable'"});
        _  -> ok
    end,
    AllPlugins = rabbit_plugins:list(PluginsDir),
    Enabled = rabbit_plugins:read_enabled(PluginsFile),
    ImplicitlyEnabled = rabbit_plugins:dependencies(false,
                                                    Enabled, AllPlugins),
    ToEnable = [list_to_atom(Name) || Name <- ToEnable0],
    Missing = ToEnable -- plugin_names(AllPlugins),
    NewEnabled = lists:usort(Enabled ++ ToEnable),
    NewImplicitlyEnabled = rabbit_plugins:dependencies(false,
                                                       NewEnabled, AllPlugins),
    MissingDeps = (NewImplicitlyEnabled -- plugin_names(AllPlugins)) -- Missing,
    case {Missing, MissingDeps} of
        {[],   []} -> ok;
        {Miss, []} -> throw({error_string, fmt_missing("plugins",      Miss)});
        {[], Miss} -> throw({error_string, fmt_missing("dependencies", Miss)});
        {_,     _} -> throw({error_string,
                             fmt_missing("plugins", Missing) ++
                                 fmt_missing("dependencies", MissingDeps)})
    end,
    write_enabled_plugins(PluginsFile, NewEnabled),
    case NewEnabled -- ImplicitlyEnabled of
        [] -> io:format("Plugin configuration unchanged.~n");
        _  -> print_list("The following plugins have been enabled:",
                         NewImplicitlyEnabled -- ImplicitlyEnabled),
              action_change(Node, enable, NewEnabled)
    end;

action(disable, Node, ToDisable0, _Opts, PluginsFile, PluginsDir) ->
    case ToDisable0 of
        [] -> throw({error_string, "Not enough arguments for 'disable'"});
        _  -> ok
    end,
    ToDisable = [list_to_atom(Name) || Name <- ToDisable0],
    Enabled = rabbit_plugins:read_enabled(PluginsFile),
    AllPlugins = rabbit_plugins:list(PluginsDir),
    Missing = ToDisable -- plugin_names(AllPlugins),
    case Missing of
        [] -> ok;
        _  -> print_list("Warning: the following plugins could not be found:",
                         Missing)
    end,
    ToDisableDeps = rabbit_plugins:dependencies(true, ToDisable, AllPlugins),
    NewEnabled = Enabled -- ToDisableDeps,
    case length(Enabled) =:= length(NewEnabled) of
        true  -> io:format("Plugin configuration unchanged.~n");
        false -> ImplicitlyEnabled =
                     rabbit_plugins:dependencies(false, Enabled, AllPlugins),
                 NewImplicitlyEnabled =
                     rabbit_plugins:dependencies(false,
                                                 NewEnabled, AllPlugins),
                 Disabled = ImplicitlyEnabled -- NewImplicitlyEnabled,
                 print_list("The following plugins have been disabled:",
                            Disabled),
                 write_enabled_plugins(PluginsFile, NewEnabled),
                 action_change(Node, disable, Disabled)
    end.

%%----------------------------------------------------------------------------

print_error(Format, Args) ->
    rabbit_misc:format_stderr("Error: " ++ Format ++ "~n", Args).

usage() ->
    io:format("~s", [rabbit_plugins_usage:usage()]),
    rabbit_misc:quit(1).

%% Pretty print a list of plugins.
format_plugins(Pattern, Opts, PluginsFile, PluginsDir) ->
    Verbose = proplists:get_bool(?VERBOSE_OPT, Opts),
    Minimal = proplists:get_bool(?MINIMAL_OPT, Opts),
    Format = case {Verbose, Minimal} of
                 {false, false} -> normal;
                 {true,  false} -> verbose;
                 {false, true}  -> minimal;
                 {true,  true}  -> throw({error_string,
                                          "Cannot specify -m and -v together"})
             end,
    OnlyEnabled    = proplists:get_bool(?ENABLED_OPT,     Opts),
    OnlyEnabledAll = proplists:get_bool(?ENABLED_ALL_OPT, Opts),

    AvailablePlugins = rabbit_plugins:list(PluginsDir),
    EnabledExplicitly = rabbit_plugins:read_enabled(PluginsFile),
    EnabledImplicitly =
        rabbit_plugins:dependencies(false, EnabledExplicitly,
                                    AvailablePlugins) -- EnabledExplicitly,
    Missing = [#plugin{name = Name, dependencies = []} ||
                  Name <- ((EnabledExplicitly ++ EnabledImplicitly) --
                               plugin_names(AvailablePlugins))],
    {ok, RE} = re:compile(Pattern),
    Plugins = [ Plugin ||
                  Plugin = #plugin{name = Name} <- AvailablePlugins ++ Missing,
                  re:run(atom_to_list(Name), RE, [{capture, none}]) =:= match,
                  if OnlyEnabled    ->  lists:member(Name, EnabledExplicitly);
                     OnlyEnabledAll -> (lists:member(Name,
                                                     EnabledExplicitly) or
                                        lists:member(Name, EnabledImplicitly));
                     true           -> true
                  end],
    Plugins1 = usort_plugins(Plugins),
    MaxWidth = lists:max([length(atom_to_list(Name)) ||
                             #plugin{name = Name} <- Plugins1] ++ [0]),
    [format_plugin(P, EnabledExplicitly, EnabledImplicitly,
                   plugin_names(Missing), Format, MaxWidth) || P <- Plugins1],
    ok.

format_plugin(#plugin{name = Name, version = Version,
                      description = Description, dependencies = Deps},
              EnabledExplicitly, EnabledImplicitly, Missing,
              Format, MaxWidth) ->
    Glyph = case {lists:member(Name, EnabledExplicitly),
                  lists:member(Name, EnabledImplicitly),
                  lists:member(Name, Missing)} of
                {true, false, false} -> "[E]";
                {false, true, false} -> "[e]";
                {_,        _,  true} -> "[!]";
                _                    -> "[ ]"
            end,
    Opt = fun (_F, A, A) -> ok;
              ( F, A, _) -> io:format(F, [A])
          end,
    case Format of
        minimal -> io:format("~s~n", [Name]);
        normal  -> io:format("~s ~-" ++ integer_to_list(MaxWidth) ++ "w ",
                             [Glyph, Name]),
                   Opt("~s", Version, undefined),
                   io:format("~n");
        verbose -> io:format("~s ~w~n", [Glyph, Name]),
                   Opt("    Version:     \t~s~n", Version,     undefined),
                   Opt("    Dependencies:\t~p~n", Deps,        []),
                   Opt("    Description: \t~s~n", Description, undefined),
                   io:format("~n")
    end.

print_list(Header, Plugins) ->
    io:format(fmt_list(Header, Plugins)).

fmt_list(Header, Plugins) ->
    lists:flatten(
      [Header, $\n, [io_lib:format("  ~s~n", [P]) || P <- Plugins]]).

fmt_missing(Desc, Missing) ->
    fmt_list("The following " ++ Desc ++ " could not be found:", Missing).

usort_plugins(Plugins) ->
    lists:usort(fun plugins_cmp/2, Plugins).

plugins_cmp(#plugin{name = N1, version = V1},
            #plugin{name = N2, version = V2}) ->
    {N1, V1} =< {N2, V2}.

%% Return the names of the given plugins.
plugin_names(Plugins) ->
    [Name || #plugin{name = Name} <- Plugins].

%% Write the enabled plugin names on disk.
write_enabled_plugins(PluginsFile, Plugins) ->
    case rabbit_file:write_term_file(PluginsFile, [Plugins]) of
        ok              -> ok;
        {error, Reason} -> throw({error, {cannot_write_enabled_plugins_file,
                                          PluginsFile, Reason}})
    end.

action_change(Node, Action, Targets) ->
    rpc_call(Node, rabbit_plugins, Action, [Targets]).

rpc_call(Node, Mod, Action, Args) ->
    case rpc:call(Node, Mod, Action, Args, ?RPC_TIMEOUT) of
        {badrpc, nodedown} -> io:format("Plugin configuration has changed.~n");
        ok                 -> io:format("Plugin(s) ~pd.~n", [Action]);
        %% QA question: if we get into a situation where the rpc call fails,
        %% does it make sense to suggest a restart as we do here? The restart
        %% would only succeed if the failure (here) was due to a bug in the
        %% rabbit_plugins:enable/1 code afaict.
        Error              -> io:format("Unable to ~p plugin(s). "
                                        "Please restart the broker "
                                        "to apply your changes.~nError: ~p~n",
                                        [Action, Error])
    end.

