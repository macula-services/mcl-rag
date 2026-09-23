%%% @doc Chunk embedding worker.
%%%
%%% Takes a list of chunks (from `markdown_chunker'), embeds each via
%%% `rag_embedder' (in the CALLING process, not inside `rag_store''s
%%% gen_server), and writes each to `rag_store:put_chunk_with_vector/4'.
%%%
%%% The gen_server stays fast: it only does barrel writes, never an
%%% outbound mesh call. The embedder call (which may take 30s over the
%%% mesh) happens here, in the worker process.
%%%
%%% `embed_and_store/1' is synchronous: it processes chunks sequentially
%%% and returns when all are stored. For bulk uploads, call from a
%%% spawned process if you don't want to block the caller.
-module(rag_chunk_embedder).

-export([embed_and_store/1]).

%% @doc Embed and store a list of chunks. Each chunk is a map with at
%% least `content' (binary) and `chunk_id' (binary); other keys become
%% metadata. Returns `{Stored, Errors}': how many chunks were written
%% with their vector, and one `{ChunkId, Reason}' per chunk that was
%% not (embedder failure or store failure). Chunks are independent: one
%% failure never stops the rest.
-spec embed_and_store([map()]) -> {non_neg_integer(), [{binary(), term()}]}.
embed_and_store(Chunks) when is_list(Chunks) ->
    lists:foldl(fun embed_one/2, {0, []}, Chunks).

embed_one(#{chunk_id := ChunkId, content := Content} = Chunk, {Ok, Err}) ->
    Meta = maps:without([chunk_id, content], Chunk),
    case rag_embedder:embed(Content) of
        {ok, Vector} -> store_chunk(ChunkId, Content, Meta, Vector, Ok, Err);
        {error, Reason} -> {Ok, [{ChunkId, Reason} | Err]}
    end.

store_chunk(ChunkId, Content, Meta, Vector, Ok, Err) ->
    case rag_store:put_chunk_with_vector(ChunkId, Content, Meta, Vector) of
        ok -> {Ok + 1, Err};
        {error, Reason} -> {Ok, [{ChunkId, Reason} | Err]}
    end.
