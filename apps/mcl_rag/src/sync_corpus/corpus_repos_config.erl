%%% @doc Reads the corpus-repos config file: which git repos
%%% `corpus_git_sync' clones/fast-forwards and `refresh_corpus_scheduler'
%%% walks for content changes. Shared by both (rather than each parsing
%%% its own copy) since they need the exact same repo list and the exact
%%% same id -> clone-path derivation, and a mismatch between the two
%%% would silently point them at different directories for "the same"
%%% repo.
%%%
%%% Deliberately re-read from disk on every call, not cached: the file
%%% is bind-mounted read-only from this repo's deploy/corpus-repos.json
%%% (see deploy/docker-compose.yml) -- re-reading a small JSON file each poll tick is cheap, and it's what
%%% makes a repo list edit take effect on this service's very next tick
%%% with no restart, the same "observe git, apply on change" shape the
%%% repos themselves get.
%%%
%%% File shape:
%%%   {"repos": [{"id": "macula", "url": "https://...",
%%%               "branch": "main", "commit": "<40 hex>"}, ...]}
%%% EVERY ENTRY IS PINNED: `commit' is the reviewed commit corpus_git_sync
%%% checks out, and `branch' the branch that must contain it. The branch head
%%% is never followed, so a push to a corpus repo reaches answers only once a
%%% reviewed macula-fleet change names its commit here. An entry without a
%%% branch or a commit, or with a commit that is not 40 lowercase hex, refuses
%%% the whole list, naming the entry: nothing moves, and no repo falls back to
%%% following its branch.
-module(corpus_repos_config).

-export([read/0]).

-type repo() :: #{id := binary(), url := binary(), branch := binary(), commit := binary(),
                  path := binary()}.
-export_type([repo/0]).

%% Overridable so a test can point this at a fixture file instead of
%% the real mount -- same convention `corpus_root'/`data_dir' use.
-spec config_path() -> string().
config_path() ->
    application:get_env(mcl_rag, corpus_repos_config,
                         "/etc/mcl-rag/corpus-repos.json").

-spec read() -> {ok, [repo()]} | {error, term()}.
read() ->
    read_file(config_path()).

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
        {ok, Repo} -> pinned(Rest, [Repo | Acc]);
        {error, _} = E -> E
    end.

entry(#{<<"id">> := Id, <<"url">> := Url} = R) ->
    checked(Id, Url, maps:get(<<"branch">>, R, <<>>), maps:find(<<"commit">>, R)).

checked(Id, _Url, <<>>, _Commit) -> {error, {missing_branch, Id}};
checked(Id, _Url, _Branch, error) -> {error, {unpinned_repo, Id}};
checked(Id, Url, Branch, {ok, Commit}) ->
    sha(Id, Commit, is_binary(Commit) andalso re:run(Commit, <<"^[0-9a-f]{40}$">>) =/= nomatch,
        #{id => Id, url => Url, branch => Branch, commit => Commit, path => clone_path(Id)}).

sha(_Id, _Commit, true, Repo) -> {ok, Repo};
sha(Id, Commit, false, _Repo) -> {error, {malformed_commit, Id, Commit}}.

clone_path(Id) ->
    DataDir = application:get_env(mcl_rag, data_dir, "/data"),
    iolist_to_binary(filename:join([DataDir, "corpus", Id])).
