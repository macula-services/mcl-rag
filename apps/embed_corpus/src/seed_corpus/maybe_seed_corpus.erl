%%% @doc Handler for `seed_corpus_v1`.
%%%
%%% Bulk-loads a directory of markdown into `rag_store'. Walks files,
%%% header-chunks each, embeds every chunk in this process and persists
%%% content + vector via `rag_chunk_embedder:embed_and_store/1' (barrel
%%% never embeds on its own here: `rag_store''s policy has `fields => []',
%%% so a chunk written without a vector is never a search hit). Also
%%% persists one verbatim `rag_store:upsert_source/1'
%%% record per file (`document_id'/`source_path' both the file's
%%% corpus-relative path), matching what `ingest_document'/`upload_knowledge'
%%% already do per-document — bulk-seeded files are exact-fetchable the
%%% same way single-uploaded ones are, not chunks-only.
%%%
%%% This is a control-plane operation (rebuild from filesystem), the bulk
%%% counterpart to the per-document `ingest_document'/`embed_document'
%%% pair. Neither path is event-sourced: see `embed_document_v1' for why.
-module(maybe_seed_corpus).

-export([seed/1, seed_async/1]).

-type stats() :: #{
    files       := non_neg_integer(),
    chunks      := non_neg_integer(),
    embeds      := non_neg_integer(),
    embed_errors := non_neg_integer(),
    sources     := non_neg_integer(),
    source_errors := non_neg_integer(),
    skipped     := non_neg_integer(),
    elapsed_ms  := non_neg_integer()
}.

%%% Public entry — synchronous

-spec seed(seed_corpus_v1:t() | map()) -> {ok, stats()} | {error, term()}.
seed(Cmd) when is_tuple(Cmd) ->
    case seed_corpus_v1:validate(Cmd) of
        ok ->
            RootDir = seed_corpus_v1:get_root_dir(Cmd),
            Glob    = seed_corpus_v1:get_glob(Cmd),
            Exclude = seed_corpus_v1:get_exclude_globs(Cmd),
            do_seed(RootDir, Glob, Exclude);
        {error, _} = E -> E
    end;
seed(Params) when is_map(Params) ->
    case seed_corpus_v1:from_map(Params) of
        {ok, Cmd}      -> seed(Cmd);
        {error, _} = E -> E
    end.

%%% Public entry — async (fire-and-forget worker process)

-spec seed_async(seed_corpus_v1:t() | map()) -> {ok, #{job_pid := pid()}} | {error, term()}.
seed_async(Params) ->
    Owner = self(),
    Pid = spawn(fun() -> Owner ! {seed_done, self(), seed(Params)} end),
    {ok, #{job_pid => Pid}}.

%%% Internals

do_seed(undefined, _Glob, _Exclude) ->
    {error, missing_root_dir};
do_seed(RootDir, Glob, Exclude) when is_binary(RootDir) ->
    do_seed(binary_to_list(RootDir), Glob, Exclude);
do_seed(RootDir, Glob, Exclude) when is_list(RootDir) ->
    case filelib:is_dir(RootDir) of
        false -> {error, {root_dir_not_found, RootDir}};
        true  -> walk_and_index(RootDir, to_str(Glob), to_strs(Exclude))
    end.

walk_and_index(RootDir, Glob, Excludes) ->
    Started = erlang:monotonic_time(millisecond),
    Files = filelib:wildcard(filename:join(RootDir, Glob)),
    Filtered = lists:filter(fun(F) -> not excluded(F, Excludes) end, Files),
    Stats0 = #{files => 0, chunks => 0, embeds => 0,
               embed_errors => 0, sources => 0, source_errors => 0,
               skipped => 0, elapsed_ms => 0},
    logger:info("[seed_corpus] starting: root=~ts files=~p (after excludes from ~p)",
                [RootDir, length(Filtered), length(Files)]),
    Stats = lists:foldl(
        fun(File, Acc) -> ingest_file(File, RootDir, Acc) end,
        Stats0,
        Filtered
    ),
    Stats1 = Stats#{
        files      => length(Filtered),
        elapsed_ms => erlang:monotonic_time(millisecond) - Started
    },
    logger:info("[seed_corpus] done: ~p", [Stats1]),
    {ok, Stats1}.

ingest_file(AbsPath, RootDir, Acc0) ->
    %% RootDir ++ "/" only strips correctly when RootDir itself has no
    %% trailing slash -- a caller-supplied RootDir ending in "/" (e.g.
    %% Common Test's own priv_dir) doubles the slash, the prefix never
    %% matches, and RelPath silently becomes the full absolute path
    %% instead of relative. Normalize first.
    Prefix = string:trim(RootDir, trailing, "/") ++ "/",
    RelPath = list_to_binary(string:replace(AbsPath, Prefix, "", leading)),
    case markdown_chunker:chunk_file(AbsPath, RelPath) of
        {ok, Chunks} ->
            Acc1 = store_source(AbsPath, RelPath, Acc0),
            store_chunks_or_skip(Chunks, Acc1);
        {error, Reason} ->
            logger:warning("[seed_corpus] read error: ~ts ~p", [AbsPath, Reason]),
            bump(skipped, Acc0)
    end.

store_chunks_or_skip([], Acc)     -> bump(skipped, Acc);
store_chunks_or_skip(Chunks, Acc) ->
    count_embedded(rag_chunk_embedder:embed_and_store(Chunks), Acc).

%% Verbatim record alongside the chunks above -- same file, read once
%% more here since markdown_chunker:chunk_file/2 keeps its own read
%% internal rather than returning the bytes it consumed.
store_source(AbsPath, RelPath, Acc) ->
    case file:read_file(AbsPath) of
        {ok, RawBytes} ->
            Source = #{
                document_id => RelPath,
                source_path => RelPath,
                source_type => <<"markdown">>,
                raw_bytes   => RawBytes
            },
            source_stored(rag_store:upsert_source(Source), RelPath, Acc);
        {error, Reason} ->
            logger:warning("[seed_corpus] source read error path=~ts ~p", [RelPath, Reason]),
            bump(source_errors, Acc)
    end.

source_stored(ok, _RelPath, Acc) ->
    bump(sources, Acc);
source_stored({error, Reason}, RelPath, Acc) ->
    logger:warning("[seed_corpus] source store error path=~ts ~p", [RelPath, Reason]),
    bump(source_errors, Acc).

count_embedded({Stored, Errors}, Acc) ->
    lists:foreach(fun({Id, Reason}) ->
                      logger:warning("[seed_corpus] embed error chunk=~s ~p", [Id, Reason])
                  end, Errors),
    Failed = length(Errors),
    Acc#{chunks       => maps:get(chunks, Acc) + Stored + Failed,
         embeds       => maps:get(embeds, Acc) + Stored,
         embed_errors => maps:get(embed_errors, Acc) + Failed}.

excluded(_File, []) -> false;
excluded(File, Globs) ->
    lists:any(fun(G) -> match_glob(File, G) end, Globs).

%% Match a glob loosely: substring OR filename:match-like semantics
%% (filelib:wildcard returns absolute paths; we accept naive substring globs).
match_glob(File, Glob) ->
    %% Naive: substring match on the path. Covers `_build`, `priv`, `assets/`.
    string:find(File, Glob) =/= nomatch.

bump(Key, Acc) when is_atom(Key) ->
    maps:update_with(Key, fun(V) -> V + 1 end, Acc).

to_str(undefined)              -> "**/*.md";
to_str(B) when is_binary(B)    -> binary_to_list(B);
to_str(L) when is_list(L)      -> L.

to_strs(undefined)             -> [];
to_strs(L) when is_list(L)     ->
    [case X of B when is_binary(B) -> binary_to_list(B); S -> S end || X <- L].
