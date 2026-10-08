%%% @doc Rustler NIF entry module.
%%%
%%% Loads `priv/lib/libmcl_rag_corpus_sync_nif.{so,dylib,dll}`. The
%%% Rust implementation lives in
%%% `native/mcl_rag_corpus_sync_nif/src/lib.rs' -- clones a repo if
%%% the local path isn't a checkout yet, fetches the branch and checks out its
%%% head (mcl-rag#24: knowledge follows its branch), via vendored libgit2, no
%%% OS `git` binary involved. The Erlang body below is a placeholder that
%%% errors out if the NIF failed to load -- it should never be hit at runtime.
-module(mcl_rag_corpus_sync_nif).

-export([sync_to_head/3]).

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

%% @doc Ensure `Path' is a checkout of `Url' at the head of `Branch', and say
%% which commit that is.
%%
%% `{ok, Head, up_to_date}' -- already at the head, clean.
%% `{ok, Head, {moved, FromSha}}' -- checked out at `Head' (`FromSha' is empty
%% on a fresh clone).
%% `{error, {git_error, Message}}' -- any libgit2 failure, with its own
%% message text, not swallowed; the checkout is left where it was.
-spec sync_to_head(binary(), binary(), binary()) ->
    {ok, binary(), up_to_date | {moved, binary()}} | {error, {git_error, binary()}}.
sync_to_head(_Url, _Path, _Branch) -> ?NIF_NOT_LOADED.
