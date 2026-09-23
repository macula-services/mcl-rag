%%% @doc Handler for `retire_document': a document leaves the corpus
%%% entirely -- every chunk recorded against its `source_path' AND the
%%% source record `ingest_document'/`seed_corpus'/the corpus git loop
%%% wrote. Afterwards `get_source_by_id', `list_sources_page' and
%%% `get_document_verbatim' no longer know the document, and semantic
%%% search no longer hits it.
%%%
%%% `prune_chunks' deliberately keeps the source record (a re-embed needs
%%% it to chunk from). This desk is for the other case: the document is
%%% gone for good.
%%%
%%% **Orphan chunks are retirable here and nowhere else.** `prune_chunks'
%%% resolves a document through its source record and answers
%%% `not_ingested' without one, so chunks that outlived their source --
%%% or never had one, as the earliest `seed_corpus' wrote chunks only --
%%% could not be removed by any capability at all. Found live
%%% (2026-09-02): 33 markdown files deleted from hecate-corpus months ago
%%% were still being returned by semantic search as current guidance,
%%% with no source record to retire them by. So a missing source record
%%% is not an error here: the id IS the `source_path' in that case, and
%%% the chunks go.
%%%
%%% Not event-sourced, for the same reason as `embed_document_v1'.
-module(maybe_retire_document).

-export([retire/1]).

%% Same bound `prune_chunks' uses: large enough for any one document,
%% and `rag_store' has no unlimited query.
-define(MAX_DOCUMENT_CHUNKS, 10000).

-spec retire(map()) -> {ok, #{document_id := binary(), pruned := non_neg_integer()}} |
                        {error, term()}.
retire(Params) when is_map(Params) ->
    case retire_document_v1:from_map(Params) of
        {ok, Cmd}      -> retire_cmd(Cmd);
        {error, _} = E -> E
    end.

retire_cmd(Cmd) ->
    case retire_document_v1:validate(Cmd) of
        ok         -> do_retire(retire_document_v1:get_document_id(Cmd));
        {error, R} -> {error, R}
    end.

do_retire(Id) ->
    with_source(rag_store:get_source(Id), Id).

%% A document with a source record: prune by the path that record
%% carries (which need not equal the id), then drop the record itself.
with_source({ok, #{source_path := Path}}, Id) ->
    forget_chunks_then(Path, Id, source);
%% No source record: the id is the only path there is. Chunks under it
%% are the orphans described above; none means there is genuinely no
%% such document.
with_source({error, not_found}, Id) ->
    forget_chunks_then(Id, Id, no_source).

forget_chunks_then(Path, Id, Kind) ->
    case rag_store:list_chunks_by_source(Path, ?MAX_DOCUMENT_CHUNKS) of
        {ok, Chunks}   -> forgotten(Chunks, Id, Kind);
        {error, _} = E -> E
    end.

%% Chunks first, then the source record: a failure in between leaves a
%% chunk-less source (harmless, and re-runnable), never orphan chunks
%% that no listing can reach any more.
forgotten([], _Id, no_source) ->
    {error, not_ingested};
forgotten(Chunks, Id, Kind) ->
    lists:foreach(fun(#{chunk_id := ChunkId}) -> rag_store:forget_chunk(ChunkId) end, Chunks),
    source_forgotten(forget_source(Kind, Id), Id, length(Chunks)).

forget_source(source, Id)     -> rag_store:forget_source(Id);
forget_source(no_source, _Id) -> ok.

source_forgotten(ok, Id, Pruned)          -> {ok, #{document_id => Id, pruned => Pruned}};
source_forgotten({error, _} = E, _Id, _N) -> E.
