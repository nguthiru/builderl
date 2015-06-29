%% Copyright (c) 2015, Grzegorz Junka
%% All rights reserved.
%%
%% Redistribution and use in source and binary forms, with or without
%% modification, are permitted provided that the following conditions are met:
%%
%% * Redistributions of source code must retain the above copyright notice,
%%   this list of conditions and the following disclaimer.
%% * Redistributions in binary form must reproduce the above copyright notice,
%%   this list of conditions and the following disclaimer in the documentation
%%   and/or other materials provided with the distribution.
%%
%% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
%% AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
%% IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
%% ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
%% LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
%% CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
%% SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
%% INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
%% CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
%% ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
%% EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

-module(bld_rel).

-include_lib("builderl/include/builderl.hrl").

-export([mk_dev/0, mk_rel/1]).

-define(RELTOOL_CONFIG, "etc/reltool.config").

%% Location of the vm_local.args file used when starting local VMs
-define(LOCAL_VM_ARGS, "tmp/vm_local.args").

%% Where the reltool release will be created
-define(REL_PATH, "tmp/rel").

%% File with name of the current release (used when creating the .tar.gz)
-define(RELEASE_DATA, "tmp/release.data").

%%------------------------------------------------------------------------------
%% Generates files (.rel, .script, .boot) that can be used to boot the release
%% targets (as found in reltool.config) in the local development environment.
%% (i.e. without creating the actual release).

mk_dev() ->
    File = get_reltool_config(),
    BldCfg = get_builderl_config(File),
    CodePaths = get_code_paths(File),

    [process_dev(Config, CodePaths) || {config, _} = Config <- File],

    write_vm_local_args(CodePaths),

    ErtsVsn = erlang:system_info(version),
    Vsn = bld_lib:keyget(boot_version, BldCfg),
    write_start_erl_data(ErtsVsn, Vsn),
    write_build_info(Vsn),
    write_builderl_config(Vsn, BldCfg),

    io:format("Finished.~n", []).


mk_rel(BldLink) ->
    File = get_reltool_config(),
    BldCfg = get_builderl_config(File),
    {ok, CWD} = file:get_cwd(),
    io:format("Ensure dir exists: ~p~n", [CWD ++ "/" ++ ?REL_PATH ++ "/"]),
    ok = filelib:ensure_dir(?REL_PATH ++ "/"),

    [process_rel(Config) || {config, _} = Config <- File],

    link_builderl(BldLink, ?REL_PATH),

    Vsn = bld_lib:keyget(boot_version, BldCfg),
    RelDir = filename:join("releases", Vsn),
    bld_lib:cp_file(RelDir, filename:join(?REL_PATH, RelDir), ?BUILDERL_CONFIG),

    io:format("Create version information: '~s': ", [?RELEASE_DATA]),
    bld_lib:check_file_op(file:write_file(?RELEASE_DATA, Vsn)).

%%------------------------------------------------------------------------------

get_reltool_config() ->
    case file:consult(?RELTOOL_CONFIG) of
        {ok, File} ->
            File;
        {error, Error} ->
            Msg = "Can't read file '~s':~nError: ~p~n",
            io:format(standard_error, Msg, [?RELTOOL_CONFIG, Error]),
            halt(1)
    end.


get_builderl_config(File) ->
    Config = proplists:get_value(builderl, File),
    DeepRels = [ [R || {rel, R, _, _} <- S] || {config, {sys, S}} <- File],
    Rels = lists:foldl(fun(List, Acc) -> List ++ Acc end, [], DeepRels),
    RelTypes = proplists:get_value(release_types, Config, []),
    CmdRel = get_cmd_rel(Config),
    verify_rel_names(Rels, [X || {_, X, _, _, _} <- RelTypes] ++ CmdRel),
    Config.

get_cmd_rel(Cfg) ->
    case lists:keyfind(setup_config, 1, Cfg) of
        false -> [];
        {setup_config, undefined, _, _} -> [];
        {setup_config, CmdRel, _, _} -> [CmdRel]
    end.

verify_rel_names(Rels, [N | T]) ->
    case lists:member(N, Rels) of
        false -> halt_bad_rel_name(N);
        true -> verify_rel_names(Rels, T)
    end;
verify_rel_names(_Rels, []) ->
    ok.

halt_bad_rel_name(Name) ->
    Msg = "Error: release '~s' is not defined in '~s', aborting.~n",
    io:format(Msg, [Name, ?RELTOOL_CONFIG]),
    halt(1).


get_code_paths(File) ->
    Lists = [proplists:get_value(lib_dirs, Sys, [])
             || {config, {sys, Sys}} <- File],
    LibDirs = lists:usort(lists:merge(Lists)),
    list_ebins(LibDirs, []).

list_ebins([Dir|T], Acc) ->
    list_ebins(T, filelib:wildcard(Dir ++ "/*/ebin") ++ Acc);
list_ebins([], Acc) ->
    lists:reverse(Acc).

%%------------------------------------------------------------------------------

process_dev({config, {sys, Sys}} = Config, CodePaths) ->
    io:format(" => Retrieving release configuration...", []),
    {ok, Server} = reltool:start_server([Config]),
    RelList = [Rel || {rel, Rel, _, _} <- Sys],
    RelFun = fun(Rel, {ok, Release}) -> {Rel, Release} end,
    Releases = [RelFun(R, reltool:get_rel(Server, R)) || R <- RelList],
    ok = reltool:stop(Server),
    io:format("OK~n", []),

    LibDirs = proplists:get_value(lib_dirs, Sys, []),
    BootRel = inc_get_boot_rel(Sys),
    process_boot_rel(CodePaths, LibDirs, BootRel, Releases).

process_boot_rel(CodePaths, LibDirs, Rel, Releases) ->
    {release, {Rel, BootVsn}, {erts, _ErtsVsn}, _Apps}
        = proplists:get_value(Rel, Releases),

    DirBase = get_release_dir(BootVsn),

    Apps = get_apps(Releases),
    ValidPaths = filter_paths(CodePaths, Apps, []),

    VmVars = filename:join(DirBase, Rel ++ ".data"),
    io:format(" => Create file: ~s~n", [VmVars]),
    Args = [{paths, ValidPaths}, {lib_dirs, LibDirs}, {rel_version, BootVsn}],
    Term = lists:flatten(io_lib:format("~p.~n~p.~n~p.~n", Args)),
    ok = file:write_file(VmVars, Term),

    code:add_paths(ValidPaths),
    lists:foreach(fun(Elem) -> make_rel(DirBase, Elem) end, Releases),
    [code:del_path(Path) || Path <- ValidPaths].

get_release_dir(BootVsn) ->
    DirBase = filename:join(["releases", BootVsn]),
    io:format(" => Ensure dir exists: ~p~n", [DirBase ++ "/"]),
    ok = filelib:ensure_dir(DirBase ++ "/"),
    DirBase.

get_apps(Releases) ->
    Fun = fun({_, {release, _, {erts, _}, Apps}}, Acc) -> Apps ++ Acc end,
    All = lists:foldl(Fun, [], Releases),
    lists:usort([element(1, App) || App <- All]).

filter_paths([Path|T], Apps, Acc) ->
    [_, Name, _] = filename:split(Path),
    case catch lists:member(list_to_existing_atom(Name), Apps) of
        true -> filter_paths(T, Apps, [Path|Acc]);
        false -> filter_paths(T, Apps, Acc);
        {'EXIT', _} -> filter_paths(T, Apps, Acc)
    end;
filter_paths([], _Apps, Acc) ->
    Acc.

%%------------------------------------------------------------------------------

process_rel({config, {sys, Sys}} = Config) ->
    BootRel = inc_get_boot_rel(Sys),
    io:format("Create release '~s' in '~s'... ~n", [BootRel, ?REL_PATH]),
    {ok, Server} = reltool:start_server([Config]),
    check_result(reltool:create_target(Server, ?REL_PATH ++ "/")),
    ok = reltool:stop(Server).

check_result(ok) ->
    io:format("Done.~n");
check_result({error, Reason}) ->
    io:format("Error:~n~p~n", [Reason]).

make_rel(Dir, {Rel, Release}) ->
    PathBase = filename:join(Dir, Rel),
    RelFile = PathBase ++ ".rel",
    io:format(" => Create file: ~s~n", [RelFile]),
    ok = file:write_file(RelFile, io_lib:format("~p.~n", [Release])),
    io:format(" => Create release: ~s~n", [Rel]),
    ok = systools:make_script(PathBase),
    io:format("Release '~s' created.~n~n", [Rel]).

%%------------------------------------------------------------------------------

inc_get_boot_rel(Sys) ->
    case proplists:get_value(boot_rel, Sys) of
        undefined ->
            io:format("Error, can't find 'boot_rel' tuple, aborting!~n"),
            halt(1);
        BootRel ->
            BootRel
    end.


write_vm_local_args(CodePaths) ->
    PathsArg = "-pa " ++ string:join(CodePaths, " "),
    Vars = [{options, [force]}, {<<"%PATHS%">>, PathsArg}],
    bld_lib:process_file(["etc", "vm_local.args.src"], ?LOCAL_VM_ARGS, Vars).


write_start_erl_data(ErtsVsn, Vsn) ->
    DataFile = filename:join("releases", "start_erl.data"),
    io:format(" => Create file: ~s~n", [DataFile]),
    ok = file:write_file(DataFile, io_lib:format("~s ~s~n", [ErtsVsn, Vsn])).


write_build_info(Vsn) ->
    {{Y,M,D},{H,N,_}} = calendar:universal_time(),
    io:format(" => Create file: ~s~n", [?BUILD_INFO]),
    Info = [<<"Build v">>, Vsn, " ",
            io_lib:format("~4.10.0B-~2.10.0B-~2.10.0B ~2.10.0B:~2.10.0B.~n",
                          [Y, M, D, H, N])],
    ok = file:write_file(?BUILD_INFO, Info).


write_builderl_config(RelVsn, Cfg) ->
    File = filename:join(["releases", RelVsn, ?BUILDERL_CONFIG]),
    io:format(" => Create file: ~s~n", [File]),
    Terms = proplists:get_value(release_types, Cfg, []),
    Recs = [{node_type, A, B, C, D, E} || {A, B, C, D, E} <- Terms],
    ToWrite = Recs ++ set_up_cfg(Cfg) ++ def_nodes(Cfg) ++ def_joins(Cfg),
    bld_lib:write_terms(File, ToWrite).

set_up_cfg(Cfg) ->
    case lists:keyfind(setup_config, 1, Cfg) of
        false ->
            [];
        {setup_config, CmdRel, SetupApp, SetupMod} ->
            [{cmd_release, CmdRel},
             {setup_application, SetupApp},
             {setup_module, SetupMod}]
    end.

def_nodes(Cfg) ->
    get_tuple_list(default_nodes, Cfg).

def_joins(Cfg) ->
    get_tuple_list(default_joins, Cfg).

get_tuple_list(Key, List) ->
    case lists:keyfind(Key, 1, List) of
        false -> [];
        Val -> [Val]
    end.


link_builderl(LinkPath, RelPath) ->
    Ebin = filename:join(LinkPath, "ebin"),
    To = filename:join(["..", "lib", bld_load:current_app_vsn(Ebin)]),
    bld_lib:mk_link(To, filename:join(RelPath, LinkPath)).
