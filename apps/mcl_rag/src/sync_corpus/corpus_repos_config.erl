%%% @doc Reads the corpus-repos config file: which git repos
%%% `refresh_corpus_scheduler' follows, and where each one's checkout lives
%%% (the id -> clone-path derivation lives here, once).
%%%
%%% Deliberately re-read from disk on every call, not cached: re-reading a
%%% small JSON file each poll tick is cheap, and it's what makes a repo list
%%% edit take effect on this service's very next tick with no restart.
%%%
%%% Where the list is: `MCL_RAG_CORPUS_REPOS' (env), else the app env
%%% `corpus_repos_config', else `/etc/mcl-rag/corpus-repos.json', the mount
%%% msi00's unit uses. deploy/corpus-repos.json is the list this repo ships.
%%%
%%% File shape:
%%%   {"repos": [{"id": "macula", "url": "https://...", "branch": "main"}, ...]}
%%% An entry may also carry two optional keys (mcl-rag#5):
%%%   "depth": 1        fetch only that many commits of the branch (shallow);
%%%                     absent or 0 fetches the full history
%%%   "paths": ["docs"] materialise and ingest only these prefixes; absent
%%%                     means the whole tree
%%% NOTHING IS PINNED (mcl-rag#24): knowledge evolves, so the node follows each
%%% entry's branch head, and every chunk names the commit it came from.
%%%
%%% The rules are published as schema/corpus-repos.schema.json (a test holds
%%% the two together): exactly the keys id, url, branch, depth and paths; an id
%%% of lowercase letters, digits and dashes (it names the checkout directory,
%%% so it can neither leave it nor collide with another); an https url or an
%%% absolute path on the box (a local mirror; no credentials either way); a
%%% non-empty branch; a depth of a positive integer; paths a non-empty list of
%%% strings, each relative to the repo root, no leading slash or dot and no
%%% `..' segment (so one can never name its way out of the checkout). A list
%%% breaking any of them, a leftover `commit' included, is refused whole,
%%% naming the entry.
-module(corpus_repos_config).

-export([read/0, path/0, rules/0]).

-type repo() :: #{id := binary(), url := binary(), branch := binary(),
                  depth := non_neg_integer(), paths := [binary()], path := binary()}.
-export_type([repo/0]).

-define(REQUIRED, [<<"id">>, <<"url">>, <<"branch">>]).
-define(OPTIONAL, [<<"depth">>, <<"paths">>]).
-define(ID, <<"^[a-z0-9][a-z0-9-]*$">>).
-define(URL, <<"^(https://|/)">>).
%% A repo-root-relative path: letters, digits and . _ - / beyond the first
%% character, and no `..' segment (the negative lookahead), so a path can
%% never name its way out of the checkout. Written once here; the schema
%% carries the same string and a test holds them equal.
-define(PATH, <<"^(?!.*(?:^|/)\\.\\.(?:/|$))[A-Za-z0-9][A-Za-z0-9._/-]*$">>).

%% @doc The file the list is read from: `MCL_RAG_CORPUS_REPOS', else the app
%% env `corpus_repos_config' (a test's fixture), else the default mount.
-spec path() -> string().
path() ->
    path(os:getenv("MCL_RAG_CORPUS_REPOS")).

path(Env) when Env =:= false; Env =:= "" ->
    application:get_env(mcl_rag, corpus_repos_config, "/etc/mcl-rag/corpus-repos.json");
path(Env) ->
    Env.

%% @doc The rules an entry must meet, as schema/corpus-repos.schema.json
%% publishes them. `patterns' covers the string keys `read/0' checks with
%% `matches/2'; `path_pattern' is the shape of one `paths' element and
%% `depth_minimum' the smallest accepted depth.
-spec rules() -> #{required := [binary()], optional := [binary()],
                   patterns := #{binary() => binary()}, path_pattern := binary(),
                   depth_minimum := pos_integer()}.
rules() ->
    #{required => ?REQUIRED,
      optional => ?OPTIONAL,
      patterns => #{<<"id">> => ?ID, <<"url">> => ?URL},
      path_pattern => ?PATH,
      depth_minimum => 1}.

-spec read() -> {ok, [repo()]} | {error, term()}.
read() ->
    read_file(path()).

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin}       -> decode(Bin);
        {error, Reason} -> {error, {config_read_failed, Reason}}
    end.

%% jsx:decode/2 throws on malformed input -- same try/catch shape
%% mcl_rag_http:decode_body/2 already uses for the identical reason
%% (no non-throwing variant), converting a parse crash into a normal
%% error tuple at this config-loading boundary.
decode(Bin) ->
    try jsx:decode(Bin, [return_maps]) of
        Decoded -> repos_from(Decoded)
    catch
        _:_ -> {error, invalid_json}
    end.

repos_from(#{<<"repos">> := Repos}) when is_list(Repos) ->
    listed(Repos, []);
repos_from(_) ->
    {error, missing_repos_key}.

listed([], Acc) -> {ok, lists:reverse(Acc)};
listed([R | Rest], Acc) ->
    case entry(R) of
        {ok, Repo} -> unique(seen(Repo, Acc), Repo, Rest, Acc);
        {error, _} = E -> E
    end.

seen(#{id := Id}, Acc) -> lists:member(Id, [I || #{id := I} <- Acc]).

unique(true, #{id := Id}, _Rest, _Acc) -> {error, {duplicate_id, Id}};
unique(false, Repo, Rest, Acc)         -> listed(Rest, [Repo | Acc]).

entry(R) when is_map(R) ->
    keys(maps:keys(R) -- (?REQUIRED ++ ?OPTIONAL), R);
entry(_) ->
    {error, {malformed_entry, not_an_object}}.

keys([Unknown | _], R) -> {error, {unknown_key, maps:get(<<"id">>, R, undefined), Unknown}};
keys([], R) ->
    Id = maps:get(<<"id">>, R, undefined),
    id(matches(Id, ?ID), Id, R).

id(false, Id, _R) -> {error, {malformed_id, Id}};
id(true, Id, R) ->
    Url = maps:get(<<"url">>, R, undefined),
    url(matches(Url, ?URL), Id, Url, R).

url(false, Id, Url, _R) -> {error, {unsupported_url, Id, Url}};
url(true, Id, Url, R) ->
    branch(Id, Url, maps:get(<<"branch">>, R, <<>>), R).

branch(Id, _Url, Branch, _R) when not is_binary(Branch); Branch =:= <<>> ->
    {error, {missing_branch, Id}};
branch(Id, Url, Branch, R) ->
    depth(Id, Url, Branch, R).

%% An absent depth is full history (0), which the NIF reads as "no bound".
depth(Id, Url, Branch, R) ->
    case maps:find(<<"depth">>, R) of
        error -> paths(Id, Url, Branch, 0, R);
        {ok, D} when is_integer(D), D >= 1 -> paths(Id, Url, Branch, D, R);
        {ok, D} -> {error, {malformed_depth, Id, D}}
    end.

%% An absent paths is the whole tree ([]). A present one must be a non-empty
%% list, since an empty one has no meaning distinct from absent and reading it
%% as "nothing" would silently ingest an empty corpus.
paths(Id, Url, Branch, Depth, R) ->
    case maps:find(<<"paths">>, R) of
        error -> {ok, entry_map(Id, Url, Branch, Depth, [])};
        {ok, Paths} when is_list(Paths), Paths =/= [] -> valid_paths(Id, Url, Branch, Depth, Paths);
        {ok, Paths} -> {error, {malformed_paths, Id, Paths}}
    end.

valid_paths(Id, Url, Branch, Depth, Paths) ->
    case first_bad_path(Paths) of
        none -> {ok, entry_map(Id, Url, Branch, Depth, Paths)};
        Bad -> {error, {malformed_path, Id, Bad}}
    end.

first_bad_path([P | Rest]) ->
    case matches(P, ?PATH) of
        true -> first_bad_path(Rest);
        false -> P
    end;
first_bad_path([]) -> none.

entry_map(Id, Url, Branch, Depth, Paths) ->
    #{id => Id, url => Url, branch => Branch, depth => Depth, paths => Paths,
      path => clone_path(Id)}.

%% `$' must end the value: PCRE's also matches before a trailing newline.
matches(V, Pattern) when is_binary(V) -> re:run(V, Pattern, [dollar_endonly]) =/= nomatch;
matches(_V, _Pattern)                 -> false.

clone_path(Id) ->
    DataDir = application:get_env(mcl_rag, data_dir, "/data"),
    iolist_to_binary(filename:join([DataDir, "corpus", Id])).
