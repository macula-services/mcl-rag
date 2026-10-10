%%% @doc Rustler NIF entry module.
%%%
%%% Loads `priv/lib/libmcl_rag_corpus_sync_nif.{so,dylib,dll}'. The
%%% Rust implementation lives in
%%% `native/mcl_rag_corpus_sync_nif/src/lib.rs' -- clones a repo if
%%% the local path isn't a checkout yet (the clone's fetch is bounded by
%%% `Depth' when it is positive; 0 is full history), fetches the branch
%%% (plain: a shallow checkout stays shallow, only new commits come down)
%%% and checks out its head
%%% (bounded by `Paths' when it is non-empty; [] is the whole tree), via
%%% vendored libgit2, no OS `git` binary involved. The Erlang body below is a
%%% placeholder that errors out if the NIF failed to load — it should
%%% never be hit at runtime.
-module(mcl_rag_corpus_sync_nif).

-export([sync_to_head/5]).

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

%% @doc Ensure `Path' is a checkout of `Url' at the head of `Branch'.
%%
%% `Depth' bounds the fetch of a FRESH clone: a positive integer fetches only
%% that many commits (a shallow checkout), 0 fetches the full history. A
%% checkout that already exists is not converted either way; delete it to have
%% it re-cloned under a depth. Later fetches always fetch plain, which keeps a
%% shallow checkout shallow and brings only new commits (libgit2 clears the
%% shallow marker when a fetch itself carries a depth).
%%
%% `Paths' bounds what is materialised and updated: a non-empty list of
%% repo-relative prefixes
%% (checked out exactly as `git checkout -- <path>...' would, so files
%% outside them already on disk are left in place), [] for the whole tree.
%% `corpus_repos_config' has already validated both shapes.
%%
%% `{ok, Head, up_to_date}' -- already at `Head', clean within `Paths'.
%% `{ok, Head, {moved, FromSha}}' -- checked out at `Head' (`FromSha' is
%% empty on a fresh clone).
%% `{error, {git_error, Message}}' -- any libgit2 failure, with its
%% own message text, not swallowed.
-spec sync_to_head(binary(), binary(), binary(), non_neg_integer(), [binary()]) ->
    {ok, binary(), up_to_date | {moved, binary()}} |
    {error, {git_error, binary()}}.
sync_to_head(_Url, _Path, _Branch, _Depth, _Paths) -> ?NIF_NOT_LOADED.
