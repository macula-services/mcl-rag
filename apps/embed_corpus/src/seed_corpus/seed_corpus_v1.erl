%%% @doc Command `seed_corpus_v1`.
%%%
%%% Bulk-load entry point: walk a root directory, header-chunk every
%%% markdown file, embed each chunk, persist into rag_store.
%%%
%%% This command takes the *control-plane* shape: it parameterises
%%% the walk (root, glob, excludes), it does NOT carry per-document
%%% payload. The actual document/chunk records are produced inside
%%% the handler.
-module(seed_corpus_v1).
-behaviour(evoq_command).

-export([command_type/0]).
-export([new/1, from_map/1, validate/1, to_map/1]).
-export([stream_id/1]).
-export([get_seed_id/1, get_root_dir/1, get_glob/1, get_exclude_globs/1]).

-record(seed_corpus_v1, {
    seed_id        :: binary() | undefined,
    root_dir       :: binary() | undefined,
    glob           :: binary() | undefined,
    exclude_globs  :: [binary()] | undefined
}).

-opaque t() :: #seed_corpus_v1{}.
-export_type([t/0]).

-spec command_type() -> atom().
command_type() -> seed_corpus_v1.

-spec new(map()) -> {ok, t()} | {error, term()}.
new(#{seed_id := Id} = Params) ->
    {ok, #seed_corpus_v1{
        seed_id       = Id,
        root_dir      = maps:get(root_dir,      Params, undefined),
        glob          = maps:get(glob,          Params, <<"**/*.md">>),
        exclude_globs = maps:get(exclude_globs, Params, [])
    }};
new(_) ->
    {error, missing_aggregate_id}.

-spec from_map(map()) -> {ok, t()} | {error, term()}.
from_map(#{<<"seed_id">> := Id} = Map) ->
    {ok, #seed_corpus_v1{
        seed_id       = Id,
        root_dir      = maps:get(<<"root_dir">>,      Map, undefined),
        glob          = maps:get(<<"glob">>,          Map, <<"**/*.md">>),
        exclude_globs = maps:get(<<"exclude_globs">>, Map, [])
    }};
from_map(_) ->
    {error, missing_aggregate_id}.

-spec validate(t()) -> ok | {error, term()}.
validate(#seed_corpus_v1{seed_id = undefined}) -> {error, missing_aggregate_id};
validate(#seed_corpus_v1{root_dir = undefined}) -> {error, missing_root_dir};
validate(_) -> ok.

-spec to_map(t()) -> map().
to_map(#seed_corpus_v1{} = Cmd) ->
    #{
        command_type  => seed_corpus_v1,
        seed_id       => Cmd#seed_corpus_v1.seed_id,
        root_dir      => Cmd#seed_corpus_v1.root_dir,
        glob          => Cmd#seed_corpus_v1.glob,
        exclude_globs => Cmd#seed_corpus_v1.exclude_globs
    }.

-spec stream_id(t()) -> binary().
stream_id(#seed_corpus_v1{seed_id = Id}) ->
    <<"seed-", Id/binary>>.

-spec get_seed_id(t()) -> binary() | undefined.
get_seed_id(#seed_corpus_v1{seed_id = V}) -> V.

-spec get_root_dir(t()) -> binary() | undefined.
get_root_dir(#seed_corpus_v1{root_dir = V}) -> V.

-spec get_glob(t()) -> binary() | undefined.
get_glob(#seed_corpus_v1{glob = V}) -> V.

-spec get_exclude_globs(t()) -> [binary()] | undefined.
get_exclude_globs(#seed_corpus_v1{exclude_globs = V}) -> V.
