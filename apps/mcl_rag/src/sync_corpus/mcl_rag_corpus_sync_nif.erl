%%% @doc Rustler NIF entry module.
%%%
%%% Loads `priv/lib/libmcl_rag_corpus_sync_nif.{so,dylib,dll}`. The
%%% Rust implementation lives in
%%% `native/mcl_rag_corpus_sync_nif/src/lib.rs' -- clones a repo if
%%% the local path isn't a checkout yet, fetches the branch, and checks out
%%% exactly the listed commit if the branch contains it (never the branch
%%% head), via vendored libgit2, no OS `git` binary involved. The Erlang body below is a
%%% placeholder that errors out if the NIF failed to load — it should
%%% never be hit at runtime.
-module(mcl_rag_corpus_sync_nif).

-export([sync_to_commit/4]).

-on_load(init/0).

-define(NIF_NOT_LOADED, erlang:nif_error({nif_not_loaded, ?MODULE})).

-spec init() -> ok | {error, term()}.
init() ->
    PrivDir = case code:priv_dir(mcl_rag) of
        {error, _} ->
            %% Test / dev tree: rebar puts us in _build/.../mcl_rag/ebin
            EbinDir = filename:dirname(code:which(?MODULE)),
            filename:join(filename:dirname(EbinDir), "priv");
        Dir ->
            Dir
    end,
    SoPath = filename:join([PrivDir, "lib", "libmcl_rag_corpus_sync_nif"]),
    erlang:load_nif(SoPath, 0).

%% @doc Ensure `Path' is a checkout of `Url' at exactly `Commit', which
%% `Branch' must contain.
%%
%% `{ok, up_to_date}' -- already at `Commit', clean.
%% `{ok, {moved, FromSha, ToSha}}' -- checked out at `ToSha' (`FromSha' is
%% empty on a fresh clone).
%% `{error, commit_not_on_branch}' -- `Branch' does not contain `Commit'; the
%% checkout is left where it was.
%% `{error, {git_error, Message}}' -- any other libgit2 failure, with its
%% own message text, not swallowed.
-spec sync_to_commit(binary(), binary(), binary(), binary()) ->
    {ok, up_to_date | {moved, binary(), binary()}} |
    {error, commit_not_on_branch | {git_error, binary()}}.
sync_to_commit(_Url, _Path, _Branch, _Commit) -> ?NIF_NOT_LOADED.
