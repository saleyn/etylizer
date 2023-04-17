-module(symtab).

% @doc A symbol table for information either defined in the current or some external module.

-include_lib("log.hrl").
-include_lib("parse.hrl").

-compile([nowarn_shadow_vars]).

-export_type([
    t/0
]).

-export([
    lookup_fun/3,
    find_fun/2,
    lookup_op/4,
    find_op/3,
    lookup_ty/3,
    find_ty/2,
    std_symtab/0,
    extend_symtab/3,
    empty/0,
    extend_symtab_with_module_list/3
]).

-record(tab, {
              funs :: #{ ast:global_ref() => ast:ty_scheme() },
              ops :: #{ {atom(), arity()} => ast:ty_scheme() },
              types :: #{ ast:global_ref() => ast:ty_scheme() }
}).

-opaque t() :: #tab{}.

% Get the type declared for a function. The location is the use-site
% If no such name exists, an error is thrown.
-spec lookup_fun(ast:global_ref(), ast:loc(), t()) -> ast:ty_scheme().
lookup_fun(Ref, Loc, Tab) ->
    case find_fun(Ref, Tab) of
        {ok, X} -> X;
        error -> errors:name_error(Loc, "function ~s undefined", pp:global_ref(Ref))
    end.

-spec find_fun(ast:global_ref(), t()) -> t:opt(ast:ty_scheme()).
find_fun(Ref, Tab) -> maps:find(Ref, Tab#tab.funs).

% Get the type for an operator
-spec lookup_op(atom(), arity(), ast:loc(), t()) -> ast:ty_scheme().
lookup_op(Name, Arity, Loc, Tab) ->
    case find_op(Name, Arity, Tab) of
        {ok, X} -> X;
        error -> errors:name_error(Loc, "operator ~w undefined for ~w arguments", [Name, Arity])
    end.

-spec find_op(atom(), arity(), t()) -> t:opt(ast:ty_scheme()).
find_op(Name, Arity, Tab) -> maps:find({Name, Arity}, Tab#tab.ops).

% Get the type declared for a type. The location is the use-site
% If no such name exists, an error is thrown.
-spec lookup_ty(ast:global_ref(), ast:loc(), t()) -> ast:ty_scheme().
lookup_ty(Ref, Loc, Tab) ->
    case find_ty(Ref, Tab) of
        {ok, X} -> X;
        error -> errors:name_error(Loc, "type ~s undefined", pp:global_ref(Ref))
    end.

-spec find_ty(ast:global_ref(), t()) -> t:opt(ast:ty_scheme()).
find_ty(Ref, Tab) -> maps:find(Ref, Tab#tab.types).

-spec empty() -> t().
empty() -> #tab { funs = #{}, ops = #{}, types = #{} }.

-spec std_symtab() -> t().
std_symtab() ->
    Funs =
        lists:foldl(fun({Name, Arity, T}, Map) -> maps:put({qref, erlang, Name, Arity}, T, Map) end,
                    #{},
                    stdtypes:builtin_funs()),
    Ops =
        lists:foldl(fun({Name, Arity, T}, Map) -> maps:put({Name, Arity}, T, Map) end,
                    #{},
                    stdtypes:builtin_ops()),
    #tab { funs = Funs, ops = Ops, types = #{} }.

-spec extend_symtab([ast:form()], atom(), t()) -> t().
extend_symtab(Forms, Module, Tab) ->
    lists:foldl(
      fun(Form, Tab) ->
              case Form of
                  {attribute, _, spec, Name, Arity, T, _} ->
                      Tab#tab { funs = maps:put(create_ref_tuple(Module, Name, Arity), T, Tab#tab.funs) };
                  {attribute, _, type, _, {Name, TyScm = {ty_scheme, TyVars, _}}} ->
                      Arity = length(TyVars),
                      Tab#tab { types = maps:put(create_ref_tuple(Module, Name, Arity), TyScm, Tab#tab.types) };
                  _ ->
                      Tab
              end
      end,
      Tab,
      Forms).

-spec create_ref_tuple(atom(), string(), arity()) -> tuple().
create_ref_tuple(Module, Name, Arity) ->
    case Module of
        no_module ->
            {ref, Name, Arity};
        _ ->
            {qref, Module, Name, Arity}
    end.

-spec extend_symtab_with_module_list(symtab:t(), file:filename(), [atom()]) -> symtab:t().
extend_symtab_with_module_list(Symtab, SourceDir, Modules) ->
    traverse_module_list(find_search_paths(SourceDir), Symtab, Modules).

traverse_module_list(SearchPaths, Symtab, Modules) ->
    case Modules of
        [CurrentModule | RemainingModules] ->
            {SourcePath, IncludePath} = find_module_path(SearchPaths, CurrentModule),
            ?LOG_NOTE("Path to includes ~s", IncludePath),

            RawForms = parse:parse_file_or_die(SourcePath, #parse_opts{ verbose = false, includes = [IncludePath] }),
            Forms = ast_transform:trans(SourcePath, RawForms),

            NewSymtab = symtab:extend_symtab(Forms, CurrentModule, Symtab),
            traverse_module_list(SearchPaths, NewSymtab, RemainingModules);
        [] ->
            Symtab
    end.

-spec find_module_path([file:filename()], atom()) -> {file:filename(), file:filename()}.
find_module_path(SearchPaths, Module) ->
    Filename = string:concat(atom_to_list(Module), ".erl"),
    ?LOG_NOTE("Looking for file ~s", Filename),
    {value, Result} = lists:search(
      fun(Path) ->
              SourcePath = filename:join([Path, "src"]),
              case filelib:find_file(Filename, SourcePath) of
                  {ok, _} -> true;
                  {error, not_found} -> false
              end
      end, SearchPaths),
    IncludePath = filename:join([Result, "include"]),
    {filename:join([Result, "src", Filename]), IncludePath}.

-spec find_search_paths(file:filename()) -> [file:filename()].
find_search_paths(SourceDir) ->
    ProjectRoot = find_project_root(SourceDir),
    find_otp_paths() ++ [ProjectRoot] ++ find_dependency_roots(ProjectRoot).

-spec find_otp_paths() -> [file:filename()].
find_otp_paths() ->
    RootDir = code:lib_dir(),
    {ok, Files} = file:list_dir(RootDir),
    lists:map(fun(Path) -> filename:join([RootDir, Path]) end, Files).

-spec find_dependency_roots(file:filename()) -> [file:filename()].
find_dependency_roots(ProjectDir) ->
    ProjectLibDir = filename:join([ProjectDir, "_build/default/lib"]),
    {ok, PathList} = file:list_dir(ProjectLibDir),
    lists:map(fun(Path) -> filename:join([ProjectLibDir, Path]) end, PathList).

-spec find_project_root(file:filename()) -> file:filename().
find_project_root(Directory) ->
    case filelib:is_dir(filename:join(Directory, "_build")) of
        true ->
            Directory;
        false ->
            find_project_root(filename:dirname(Directory))
    end.
