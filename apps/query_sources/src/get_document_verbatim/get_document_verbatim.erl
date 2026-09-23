%%% @doc Query desk: get_document_verbatim. Exact, byte-for-byte fetch
%%% of a corpus document by its path -- not a RAG-reranked
%%% approximation of it (that's `answer_query'/`search_chunks_semantic').
%%%
%%% Composes `rag_store:find_source_by_path/1' (path -> document_id)
%%% with `rag_store:get_source_content/1' (document_id -> raw_bytes):
%%% a source record is looked up by its path, but its content is
%%% stored keyed by `document_id', so a single path-in-content-out
%%% call needs both steps.
-module(get_document_verbatim).

-export([handle/1]).

-spec handle(binary() | undefined) -> {ok, map()} | {error, term()}.
handle(SourcePath) when is_binary(SourcePath) ->
    case rag_store:find_source_by_path(SourcePath) of
        {ok, #{document_id := DocId}} -> as_wire(rag_store:get_source_content(DocId));
        {error, _} = E                -> E
    end;
handle(_) ->
    {error, missing_source_path}.

%% `source_path' is text on the wire: a bare binary encodes as a CBOR
%% BYTE string and reaches macula-cli/macula-mcp/every non-BEAM SDK as
%% `0x...' hex, so it goes out as `{text, Bin}'. `raw_bytes' stays a
%% byte string on purpose -- it IS bytes, verbatim, and a caller hashes
%% or writes them, never reads them as prose.
as_wire({ok, #{source_path := Path} = Doc}) -> {ok, Doc#{source_path => {text, Path}}};
as_wire(Other)                              -> Other.
