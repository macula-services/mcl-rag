%%% @doc Handler for `upload_knowledge': the full server-side pipeline.
%%%
%%% 1. Stores the source record (so the document is listable).
%%% 2. Chunks the raw content via `markdown_chunker' (fast, local).
%%% 3. Embeds each chunk via `rag_chunk_embedder' (in THIS process, not
%%%    inside `rag_store''s gen_server — the gen_server stays fast).
%%% 4. Writes each chunk + vector to `rag_store'.
%%%
%%% The caller sends raw bytes; the server owns chunking and embedding.
-module(maybe_upload_knowledge).

-export([upload/1]).
%% Pure, exported for its own test coverage -- see maybe_add_knowledge's
%% own doc on why this is worth testing without an embedder or a store.
-export([with_deposited_by/2]).

-define(MAX_CHUNK_CHARS, 2000).

-spec upload(map()) -> {ok, #{document_id := binary(), chunks := non_neg_integer()}} |
                        {error, term()}.
upload(Params) when is_map(Params) ->
    case upload_knowledge_v1:from_map(Params) of
        {ok, Cmd}      -> upload_cmd(Cmd);
        {error, _} = E -> E
    end.

upload_cmd(Cmd) ->
    case upload_knowledge_v1:validate(Cmd) of
        ok         -> do_upload(Cmd);
        {error, R} -> {error, R}
    end.

do_upload(Cmd) ->
    Id = upload_knowledge_v1:get_document_id(Cmd),
    SourcePath = upload_knowledge_v1:get_source_path(Cmd),
    SourceType = upload_knowledge_v1:get_source_type(Cmd),
    RawBytes = upload_knowledge_v1:get_raw_bytes(Cmd),
    DepositedBy = upload_knowledge_v1:get_deposited_by(Cmd),
    Path = path_or_id(SourcePath, Id),
    Source = #{
        document_id => Id,
        source_path => Path,
        source_type => SourceType,
        raw_bytes => RawBytes,
        deposited_by => hex_or_undefined(DepositedBy)
    },
    source_stored(rag_store:upsert_source(Source), Id, Path, RawBytes, DepositedBy).

source_stored({error, _} = Refused, _Id, _Path, _RawBytes, _DepositedBy) ->
    Refused;
source_stored(ok, Id, Path, RawBytes, DepositedBy) ->
    Chunks = with_deposited_by(markdown_chunker:chunk_text(RawBytes, Path, ?MAX_CHUNK_CHARS), DepositedBy),
    {Stored, Errors} = rag_chunk_embedder:embed_and_store(Chunks),
    log_errors(Errors),
    {ok, #{document_id => Id, chunks => Stored}}.

%% @doc Same contract as `maybe_add_knowledge:with_deposited_by/2' --
%% see that module's own doc for the full reasoning (hex encoding,
%% `undefined' meaning no wire caller). Takes the raw pubkey, same as
%% that module, even though `do_upload/1' above also needs a hex copy
%% for the source record -- `hex_or_undefined/1' is the one place either
%% encodes it, so the two never drift.
-spec with_deposited_by([map()], binary() | undefined) -> [map()].
with_deposited_by(Chunks, undefined) ->
    Chunks;
with_deposited_by(Chunks, DepositedBy) when is_binary(DepositedBy) ->
    Hex = hex_or_undefined(DepositedBy),
    [C#{deposited_by => Hex} || C <- Chunks].

hex_or_undefined(undefined) -> undefined;
hex_or_undefined(DepositedBy) when is_binary(DepositedBy) -> binary:encode_hex(DepositedBy, lowercase).

log_errors([]) -> ok;
log_errors(Errors) ->
    lists:foreach(fun({ChunkId, Reason}) ->
        logger:warning("[upload_knowledge] chunk ~s failed: ~p", [ChunkId, Reason])
    end, Errors).

path_or_id(<<>>, Id) -> Id;
path_or_id(Path, _)   -> Path.
