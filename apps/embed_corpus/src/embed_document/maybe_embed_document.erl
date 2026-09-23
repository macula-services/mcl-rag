%%% @doc Handler for `embed_document': chunks the raw content
%%% `ingest_document' recorded against this document (read back from
%%% `rag_store', not from the command — `embed_document' carries no raw
%%% content of its own, so a document can be re-embedded without
%%% resubmitting it), embeds every chunk in THIS process via
%%% `rag_chunk_embedder' (`rag_embedder' underneath: Ollama locally,
%%% mcl-embedder over the mesh on the fleet) and writes content +
%%% vector to `rag_store' in one put. `rag_store''s barrel policy has
%%% `fields => []': barrel never embeds anything itself, so a chunk
%%% written without a vector is stored but never a search hit. That is
%%% exactly what this desk did until 2026-09-02 (found live: every
%%% git-synced corpus file was fetchable verbatim and invisible to
%%% semantic search).
%%%
%%% Same header-aware chunker `seed_corpus' uses (`markdown_chunker'). This
%%% is the audit-worthy, per-document path; `seed_corpus' is the
%%% deliberate bulk bypass. Both land in the same `rag_store' through the
%%% same `rag_chunk_embedder' call.
-module(maybe_embed_document).

-export([embed/1]).

%% Matches `markdown_chunker:chunk_file/2''s own internal default — there is
%% exactly one chunk-size policy in this codebase, not two.
-define(MAX_CHUNK_CHARS, 2000).

-spec embed(map()) -> {ok, #{document_id := binary(), chunks := non_neg_integer()}} |
                       {error, term()}.
embed(Params) when is_map(Params) ->
    case embed_document_v1:from_map(Params) of
        {ok, Cmd}      -> embed_cmd(Cmd);
        {error, _} = E -> E
    end.

embed_cmd(Cmd) ->
    case embed_document_v1:validate(Cmd) of
        ok         -> do_embed(Cmd);
        {error, R} -> {error, R}
    end.

do_embed(Cmd) ->
    Id = embed_document_v1:get_document_id(Cmd),
    case rag_store:get_source_content(Id) of
        {ok, Content} -> chunk_and_store(Id, Content);
        {error, not_found} -> {error, not_ingested};
        {error, _} = Refused -> Refused
    end.

chunk_and_store(Id, #{source_path := SourcePath, raw_bytes := RawBytes}) ->
    Path = source_path_or_id(SourcePath, Id),
    Chunks = markdown_chunker:chunk_text(RawBytes, Path, ?MAX_CHUNK_CHARS),
    stored(Id, rag_chunk_embedder:embed_and_store(Chunks)).

%% Any failed chunk fails the document. Chunks already written stay
%% written (each put is its own atomic barrel write, there is no larger
%% transaction to roll back) and a retry is safe -- every chunk id is
%% position-derived, so re-running re-writes the same ids. Reporting
%% the failure is what makes that retry happen: refresh_corpus_scheduler
%% resets the file's watermark on it.
stored(Id, {Stored, []}) ->
    {ok, #{document_id => Id, chunks => Stored}};
stored(_Id, {_Stored, Errors}) ->
    {error, {embed_failed, Errors}}.

%% `markdown_chunker' only uses this to stamp `source_path' on each chunk;
%% fall back to the document id so a document ingested without one still
%% gets a stable, non-empty tag.
source_path_or_id(<<>>, Id)  -> Id;
source_path_or_id(Path, _Id) -> Path.
