%%% @doc Rustler NIF entry module.
%%%
%%% Loads `priv/lib/libmcl_rag_corpus_sync_nif.{so,dylib,dll}`. The
%%% Rust implementation lives in
%%% `native/mcl_rag_corpus_sync_nif/src/lib.rs' -- clones a repo if
%%% the local path isn't a checkout yet, otherwise fetches `origin' for
%%% the checkout's current branch and fast-forwards it, via vendored
%%% libgit2, no OS `git` binary involved. The Erlang body below is a
%%% placeholder that errors out if the NIF failed to load — it should
%%% never be hit at runtime.
-module(mcl_rag_corpus_sync_nif).

-export([clone_or_sync/3]).

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

%% @doc Ensure `Path' is a checkout of `Url' and current with it. `Branch'
%% empty means "the remote's own default branch" (only consulted on a
%% fresh clone; an existing checkout keeps whatever branch it already has).
%%
%% `{ok, cloned}' — `Path' didn't exist yet, freshly cloned.
%% `{ok, up_to_date}' — already current, nothing to do.
%% `{ok, {fast_forwarded, FromSha, ToSha}}' — updated, working tree
%% checked out to `ToSha'.
%% `{error, not_fast_forward}' — local and remote have diverged; left
%% untouched, same safety property `git pull --ff-only` has.
%% `{error, {git_error, Message}}' — any other libgit2 failure, with its
%% own message text, not swallowed.
-spec clone_or_sync(binary(), binary(), binary()) ->
    {ok, cloned | up_to_date | {fast_forwarded, binary(), binary()}} |
    {error, not_fast_forward | {git_error, binary()}}.
clone_or_sync(_Url, _Path, _Branch) -> ?NIF_NOT_LOADED.
