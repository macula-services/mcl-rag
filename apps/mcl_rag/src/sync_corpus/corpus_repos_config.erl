%%% @doc Reads the corpus-repos config file: which git repos
%%% `corpus_git_sync' clones/fast-forwards and `refresh_corpus_scheduler'
%%% walks for content changes. Shared by both (rather than each parsing
%%% its own copy) since they need the exact same repo list and the exact
%%% same id -> clone-path derivation, and a mismatch between the two
%%% would silently point them at different directories for "the same"
%%% repo.
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
%%%   {"repos": [{"id": "macula", "url": "https://...",
%%%               "branch": "main", "commit": "<40 hex>"}, ...]}
%%% EVERY ENTRY IS PINNED: `commit' is the reviewed commit corpus_git_sync
%%% checks out, and `branch' the branch that must contain it. The branch head
%%% is never followed, so a push to a corpus repo reaches answers only once a
%%% reviewed macula-fleet change names its commit here.
%%%
%%% The rules are published as schema/corpus-repos.schema.json (a test holds
%%% the two together): exactly the keys id, url, branch and commit; an id of
%%% lowercase letters, digits and dashes (it names the checkout directory, so
%%% it can neither leave it nor collide with another); an https url or an
%%% absolute path on the box (a local mirror; no credentials either way); a
%%% non-empty branch; a commit of 40 lowercase hex. A list breaking any of
%%% them is refused whole, naming the entry: nothing moves, and no repo falls
%%% back to following its branch.
-module(corpus_repos_config).

-export([read/0, path/0, rules/0]).

-type repo() :: #{id := binary(), url := binary(), branch := binary(), commit := binary(),
                  path := binary()}.
-export_type([repo/0]).

-define(KEYS, [<<"id">>, <<"url">>, <<"branch">>, <<"commit">>]).
-define(ID, <<"^[a-z0-9][a-z0-9-]*$">>).
-define(URL, <<"^(https://|/)">>).
-define(COMMIT, <<"^[0-9a-f]{40}$">>).

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
%% publishes them.
-spec rules() -> #{required := [binary()], patterns := #{binary() => binary()}}.
rules() ->
    #{required => ?KEYS,
      patterns => #{<<"id">> => ?ID, <<"url">> => ?URL, <<"commit">> => ?COMMIT}}.

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
    pinned(Repos, []);
repos_from(_) ->
    {error, missing_repos_key}.

pinned([], Acc) -> {ok, lists:reverse(Acc)};
pinned([R | Rest], Acc) ->
    case entry(R) of
        {ok, #{id := Id} = Repo} -> unique(lists:any(fun(#{id := I}) -> I =:= Id end, Acc), Repo, Rest, Acc);
        {error, _} = E -> E
    end.

unique(true, #{id := Id}, _Rest, _Acc) -> {error, {duplicate_id, Id}};
unique(false, Repo, Rest, Acc)         -> pinned(Rest, [Repo | Acc]).

entry(R) when is_map(R) ->
    keys(maps:keys(R) -- ?KEYS, R);
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
    checked(Id, Url, maps:get(<<"branch">>, R, <<>>), maps:find(<<"commit">>, R)).

checked(Id, _Url, Branch, _Commit) when not is_binary(Branch); Branch =:= <<>> ->
    {error, {missing_branch, Id}};
checked(Id, _Url, _Branch, error) -> {error, {unpinned_repo, Id}};
checked(Id, Url, Branch, {ok, Commit}) ->
    sha(Id, Commit, matches(Commit, ?COMMIT),
        #{id => Id, url => Url, branch => Branch, commit => Commit, path => clone_path(Id)}).

sha(_Id, _Commit, true, Repo) -> {ok, Repo};
sha(Id, Commit, false, _Repo) -> {error, {malformed_commit, Id, Commit}}.

%% `$' must end the value: PCRE's also matches before a trailing newline.
matches(V, Pattern) when is_binary(V) -> re:run(V, Pattern, [dollar_endonly]) =/= nomatch;
matches(_V, _Pattern)                 -> false.

clone_path(Id) ->
    DataDir = application:get_env(mcl_rag, data_dir, "/data"),
    iolist_to_binary(filename:join([DataDir, "corpus", Id])).
