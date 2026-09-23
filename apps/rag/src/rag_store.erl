%%% @doc rag_store — the shared retrieval state.
%%%
%%% One `barrel' record-mode database (`barrel_docdb' + `barrel_vectordb'
%%% composed behind one handle, see beam-campus/barrel): a chunk's content,
%%% metadata and vector all live under its `chunk_id'.
%%%
%%% **Embedding is application-layer, not barrel-managed.** The embedding
%%% policy has `fields => []' — barrel never auto-embeds. Callers compute
%%% vectors via `rag_embedder' (in their own process, not inside this
%%% gen_server) and pass them to `put_chunk_with_vector/4'. This keeps
%%% the gen_server fast: every call is a barrel read/write, never an
%%% outbound mesh call that could block for 30s.
%%%
%%% `search_text/2' is NOT a gen_server call — it embeds the query via
%%% `rag_embedder' in the caller's process, then delegates to
%%% `search_vector/2' (which IS a gen_server call, fast).
%%%
%%% Write paths:
%%%
%%%   - `put_chunk_with_vector/4' — primary write path: content + meta
%%%     + pre-computed vector. Barrel indexes the vector synchronously.
%%%   - `put_chunk/3' — content + meta only, NO vector. Never a search
%%%     hit until `put_chunk_with_vector/4' writes the same id with a
%%%     vector. Not an ingestion path: every ingestion desk embeds via
%%%     `rag_chunk_embedder'. Used by metadata-only test fixtures.
%%%   - `forget_chunk/1' — called directly by `prune_chunks'.
%%%   - `upsert_source/1' — called directly by `ingest_document'.
%%%   - `forget_source/1' — called directly by `retire_document'.
%%%
%%% Read paths:
%%%
%%%   - `search_text/2' — embeds query externally, then vector search.
%%%   - `search_vector/2' — vector search (gen_server call, fast).
%%%   - `get/1' — `get_chunk_by_id'.
%%%   - `list_chunks_by_source/2' — `list_chunks_by_source'.
%%%   - `get_source/1' — `get_source_by_id'.
%%%   - `list_sources/2' — `list_sources_page'.
%%%
%%% Lazy boot: the gen_server starts cold; the first request opens the
%%% database. Lets the service stay up even when paths aren't yet writable
%%% (e.g. test harness, early boot).
-module(rag_store).
-behaviour(gen_server).

-export([
    start_link/0,
    put_chunk/3,
    put_chunk_with_vector/4,
    forget_chunk/1,
    tag_chunk/2,
    search_text/2,
    search_vector/2,
    get/1,
    size/0,
    upsert_source/1,
    forget_source/1,
    get_source/1,
    get_source_content/1,
    list_sources/2,
    list_chunks_by_source/2,
    find_source_by_path/1,
    get_watermark/2,
    put_watermark/3,
    put_reembed_request/1
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(DB_NAME, rag_chunks).
-define(DEFAULT_DIM, 768).
-define(SOURCE_ID_PREFIX, "source:").
-define(WATERMARK_ID_PREFIX, "watermark:").
-define(REEMBED_ID_PREFIX, "reembed:").

%% The default gen_server:call/2 timeout (5000ms) is too short for this
%% store under real load: refresh_corpus_scheduler's first-ever pass
%% over a whole unwatermarked corpus serializes hundreds of
%% put_chunk_with_vector writes (each a barrel docdb write PLUS a
%% synchronous HNSW insert) through this one gen_server, and an
%% unrelated call queued behind them -- even a cheap read like
%% get_watermark/2 -- times out waiting its turn, not because anything
%% is actually stuck. Verified live, back when the embedder round-trip
%% itself still ran inside handle_call: refresh_corpus_scheduler
%% crash-looped indefinitely on beam03 with {timeout, {gen_server, call,
%% [rag_store, {get_watermark, ...}]}} on its very first tick, every 5
%% seconds, never completing a pass. Embedding has since moved out to
%% the caller (rag_chunk_embedder), but the write burst remains. 60s
%% comfortably covers it while still surfacing a genuine hang
%% eventually, rather than waiting forever.
-define(CALL_TIMEOUT, 60000).

-record(state, {db = undefined :: map() | undefined}).

%%% API

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Insert or replace a chunk WITHOUT a vector. The chunk is stored
%% but NOT in the vector index -- semantic search never returns it until
%% `put_chunk_with_vector/4' writes the same id with a vector. Not an
%% ingestion path: those all go through `rag_chunk_embedder', and two of
%% them calling this instead was the 2026-09-02 live bug (every
%% git-synced corpus file fetchable verbatim, none of them searchable).
%% Used by metadata-only test fixtures such as the `classify_topics' suite.
-spec put_chunk(binary(), binary(), map()) -> ok | {error, term()}.
put_chunk(ChunkId, Content, Meta)
  when is_binary(ChunkId), is_binary(Content), is_map(Meta) ->
    gen_server:call(?MODULE, {put_chunk, ChunkId, Content, Meta}, ?CALL_TIMEOUT).

%% @doc Insert or replace a chunk with a pre-computed embedding vector.
%% This is the primary write path: the caller embeds content in their
%% own process (via `rag_embedder') and passes the vector here. The
%% gen_server does a fast barrel write + synchronous vector index —
%% no outbound mesh call, no blocking.
-spec put_chunk_with_vector(binary(), binary(), map(), [float()]) -> ok | {error, term()}.
put_chunk_with_vector(ChunkId, Content, Meta, Vector)
  when is_binary(ChunkId), is_binary(Content), is_map(Meta), is_list(Vector) ->
    gen_server:call(?MODULE, {put_chunk_with_vector, ChunkId, Content, Meta, Vector}, ?CALL_TIMEOUT).

-spec forget_chunk(binary()) -> ok | {error, term()}.
forget_chunk(ChunkId) when is_binary(ChunkId) ->
    gen_server:call(?MODULE, {forget_chunk, ChunkId}, ?CALL_TIMEOUT).

%% @doc Tag an existing chunk with topic labels. Merges `Topics' into
%% the chunk's document metadata (under `<<"topics">>') using the same
%% upsert-with-rev pattern as `put_chunk'. The chunk must already
%% exist — this is an enrichment step, not a creation step.
-spec tag_chunk(binary(), [binary()]) -> ok | {error, term()}.
tag_chunk(ChunkId, Topics) when is_binary(ChunkId), is_list(Topics) ->
    gen_server:call(?MODULE, {tag_chunk, ChunkId, Topics}, ?CALL_TIMEOUT).

%% @doc Semantic search from a query string. Embeds the query via
%% `rag_embedder' in the CALLER's process (not inside the gen_server),
%% then delegates to `search_vector/2' — a fast gen_server call.
%% This keeps the gen_server responsive even when the embedder is slow.
-spec search_text(binary(), pos_integer()) -> {ok, [map()]} | {error, term()}.
search_text(QueryText, TopK)
  when is_binary(QueryText), is_integer(TopK), TopK > 0 ->
    case rag_embedder:embed(QueryText) of
        {ok, Vector} -> search_vector(Vector, TopK);
        {error, _} = E -> E
    end.

-spec search_vector([float()], pos_integer()) -> {ok, [map()]} | {error, term()}.
search_vector(Vector, TopK)
  when is_list(Vector), is_integer(TopK), TopK > 0 ->
    gen_server:call(?MODULE, {search_vector, Vector, TopK}, ?CALL_TIMEOUT).

-spec get(binary()) -> {ok, map()} | {error, not_found}.
get(ChunkId) when is_binary(ChunkId) ->
    gen_server:call(?MODULE, {get, ChunkId}, ?CALL_TIMEOUT).

-spec size() -> non_neg_integer().
size() ->
    gen_server:call(?MODULE, size, ?CALL_TIMEOUT).

%% @doc Record (or update) that a document has been ingested. Map keys:
%% `document_id' (required), `source_path', `source_type', `raw_bytes',
%% `deposited_by' (all optional). `raw_bytes' is what `embed_document'
%% later reads back to chunk — with no event-sourced aggregate, the
%% source record IS where ingested content lives between the two calls.
%% `deposited_by' is the depositing caller's wire-authenticated pubkey,
%% already hex-encoded by the caller (`maybe_upload_knowledge') -- this
%% store never sees the raw bytes, same posture as every other field
%% here: it stores what it is given, it does not compute provenance.
-spec upsert_source(map()) -> ok | {error, term()}.
upsert_source(#{document_id := Id} = Source) when is_binary(Id) ->
    gen_server:call(?MODULE, {upsert_source, Source}, ?CALL_TIMEOUT).

%% @doc Remove a document's source record: afterwards the document is
%% unknown to `get_source/1', `get_source_content/1', `list_sources/2'
%% and `find_source_by_path/1'. Chunks are not touched here --
%% `retire_document' prunes them first, through `prune_chunks'.
-spec forget_source(binary()) -> ok | {error, term()}.
forget_source(DocumentId) when is_binary(DocumentId) ->
    gen_server:call(?MODULE, {forget_source, DocumentId}, ?CALL_TIMEOUT).

%% @doc The public source row: id/path/type, no `raw_bytes' (kept out of
%% the default shape the same way `chunk_meta/1' hides `_embedding' —
%% derived/bulky fields are opt-in, not default).
-spec get_source(binary()) -> {ok, map()} | {error, not_found}.
get_source(DocumentId) when is_binary(DocumentId) ->
    gen_server:call(?MODULE, {get_source, DocumentId}, ?CALL_TIMEOUT).

%% @doc Internal use (`embed_document'): the source's `source_path' and
%% `raw_bytes', to chunk. Not part of the public query surface.
-spec get_source_content(binary()) -> {ok, map()} | {error, not_found}.
get_source_content(DocumentId) when is_binary(DocumentId) ->
    gen_server:call(?MODULE, {get_source_content, DocumentId}, ?CALL_TIMEOUT).

-spec list_sources(non_neg_integer(), pos_integer()) -> {ok, [map()]}.
list_sources(Offset, Limit)
  when is_integer(Offset), Offset >= 0, is_integer(Limit), Limit > 0 ->
    gen_server:call(?MODULE, {list_sources, Offset, Limit}, ?CALL_TIMEOUT).

-spec list_chunks_by_source(binary(), pos_integer()) -> {ok, [map()]}.
list_chunks_by_source(SourcePath, Limit)
  when is_binary(SourcePath), is_integer(Limit), Limit > 0 ->
    gen_server:call(?MODULE, {list_chunks_by_source, SourcePath, Limit}, ?CALL_TIMEOUT).

%% @doc The source record for a `source_path', regardless of which
%% `document_id' it was ingested under -- `detect_corpus_change'/
%% `schedule_reembed' address a corpus by path (what a directory scan
%% actually has on hand), not by the caller-chosen id `ingest_document'
%% used. First match wins; a `source_path' is expected to be unique in
%% practice (`ingest_document' upserts by `document_id', not path, so
%% nothing enforces this at write time -- a caller ingesting the same
%% path under two different ids is a caller error this doesn't try to
%% detect).
-spec find_source_by_path(binary()) -> {ok, map()} | {error, not_found}.
find_source_by_path(SourcePath) when is_binary(SourcePath) ->
    gen_server:call(?MODULE, {find_source_by_path, SourcePath}, ?CALL_TIMEOUT).

%% @doc The last-recorded `diff_hash' for one `(corpus_id, source_path)'
%% pair -- what `detect_corpus_change' compares a freshly-computed hash
%% against to decide whether anything actually changed.
-spec get_watermark(binary(), binary()) -> {ok, #{diff_hash := binary()}} | {error, not_found}.
get_watermark(CorpusId, SourcePath) when is_binary(CorpusId), is_binary(SourcePath) ->
    gen_server:call(?MODULE, {get_watermark, CorpusId, SourcePath}, ?CALL_TIMEOUT).

-spec put_watermark(binary(), binary(), binary()) -> ok | {error, term()}.
put_watermark(CorpusId, SourcePath, DiffHash)
  when is_binary(CorpusId), is_binary(SourcePath), is_binary(DiffHash) ->
    gen_server:call(?MODULE, {put_watermark, CorpusId, SourcePath, DiffHash}, ?CALL_TIMEOUT).

%% @doc Records a re-embed request. `Req' keys: `document_id',
%% `corpus_id', `source_path' (required), `priority', `scheduled_at'
%% (optional). No worker consumes these yet -- see `maybe_schedule_reembed'
%% for what's deliberately not built here.
-spec put_reembed_request(map()) -> {ok, #{request_id := binary()}} | {error, term()}.
put_reembed_request(#{document_id := Id} = Req) when is_binary(Id) ->
    gen_server:call(?MODULE, {put_reembed_request, Req}, ?CALL_TIMEOUT).

%%% gen_server

init([]) ->
    {ok, #state{}}.

handle_call({put_chunk, Id, Content, Meta}, _From, S0) ->
    with_db(S0, fun(Db) -> put_chunk_doc(Db, Id, Content, Meta) end);

handle_call({put_chunk_with_vector, Id, Content, Meta, Vector}, _From, S0) ->
    with_db(S0, fun(Db) -> put_chunk_with_vector_doc(Db, Id, Content, Meta, Vector) end);

handle_call({forget_chunk, Id}, _From, S0) ->
    with_db(S0, fun(Db) -> normalize_write(barrel:delete_doc(Db, Id)) end);

handle_call({tag_chunk, ChunkId, Topics}, _From, S0) ->
    with_db(S0, fun(Db) -> tag_chunk_doc(Db, ChunkId, Topics) end);

handle_call({search_vector, Vector, TopK}, _From, S0) ->
    with_db(S0, fun(Db) -> to_hits(Db, barrel:search_vector(Db, Vector, #{k => TopK})) end);

handle_call({get, Id}, _From, S0) ->
    with_db(S0, fun(Db) -> chunk_from_doc(barrel:get_doc(Db, Id)) end);

handle_call(size, _From, S0) ->
    with_db(S0, fun(Db) -> chunk_count(Db) end, 0);

handle_call({upsert_source, Source}, _From, S0) ->
    with_db(S0, fun(Db) -> put_source_doc(Db, Source) end);

handle_call({forget_source, Id}, _From, S0) ->
    with_db(S0, fun(Db) -> normalize_write(barrel:delete_doc(Db, source_id(Id))) end);

handle_call({get_source, Id}, _From, S0) ->
    with_db(S0, fun(Db) -> source_from_doc(barrel:get_doc(Db, source_id(Id))) end);

handle_call({get_source_content, Id}, _From, S0) ->
    with_db(S0, fun(Db) -> source_content_from_doc(barrel:get_doc(Db, source_id(Id))) end);

handle_call({list_sources, Offset, Limit}, _From, S0) ->
    with_db(S0, fun(Db) -> list_sources_page(Db, Offset, Limit) end, {ok, []});

handle_call({list_chunks_by_source, SourcePath, Limit}, _From, S0) ->
    with_db(S0, fun(Db) -> list_chunks_by_source_page(Db, SourcePath, Limit) end, {ok, []});

handle_call({find_source_by_path, SourcePath}, _From, S0) ->
    with_db(S0, fun(Db) -> find_source_by_path_doc(Db, SourcePath) end);

handle_call({get_watermark, CorpusId, SourcePath}, _From, S0) ->
    with_db(S0, fun(Db) -> watermark_from_doc(barrel:get_doc(Db, watermark_id(CorpusId, SourcePath))) end);

handle_call({put_watermark, CorpusId, SourcePath, DiffHash}, _From, S0) ->
    with_db(S0, fun(Db) -> put_watermark_doc(Db, CorpusId, SourcePath, DiffHash) end);

handle_call({put_reembed_request, Req}, _From, S0) ->
    with_db(S0, fun(Db) -> put_reembed_request_doc(Db, Req) end);

handle_call(_, _From, S) -> {reply, {error, unknown_call}, S}.

handle_cast(_, S) -> {noreply, S}.
handle_info(_, S) -> {noreply, S}.
terminate(_, _)   -> ok.

%%% Internals — lazy open
%%
%% `Fun' returns a plain result (`ok', `{ok, _}' or `{error, _}'), never a
%% gen_server reply tuple — this is the one place that wraps it, so every
%% `handle_call' clause above reads as "what does this call actually
%% compute" with no `{reply, _, State}' boilerplate repeated per clause.
%% `size/0' and the list queries pass a 3rd-arg fallback because their
%% "no db yet" answer is a value (`0', `{ok, []}'), not an error.

with_db(S0, Fun) ->
    with_db(S0, Fun, undefined).

with_db(#state{db = undefined} = S0, Fun, OnOpenError) ->
    case open_db() of
        {ok, Db}        -> reply_result(Fun(Db), S0#state{db = Db});
        {error, _} = E  -> {reply, on_open_error(OnOpenError, E), S0}
    end;
with_db(#state{db = Db} = S0, Fun, _OnOpenError) ->
    reply_result(Fun(Db), S0).

on_open_error(undefined, Error) -> Error;
on_open_error(Fallback, _Error) -> Fallback.

reply_result(Result, State) -> {reply, Result, State}.

%% Found live (2026-08-31): the vector index was empty after every
%% container restart even though the docdb (get_chunk_by_id) survived
%% fine -- `vectordb' was never passed here, so barrel_vectordb_store
%% fell back to its own default `db_path' ("priv/barrel_vectordb_data",
%% relative to the release's cwd), never the mounted persistent volume
%% `docdb' correctly uses. barrel_vectordb_store IS itself RocksDB-
%% backed and does reload/rebuild its HNSW index from persisted
%% metadata on open (see load_or_create_index/4 there) -- this was a
%% pure missing-config bug on this side, not a real barrel limitation.
%% `fields => []' — barrel never auto-embeds. All embedding is
%% application-layer: callers compute vectors via `rag_embedder' and
%% pass them to `put_chunk_with_vector/4'. This keeps the gen_server
%% fast (no outbound mesh calls inside handle_call).
open_db() ->
    barrel:open(?DB_NAME, #{
        docdb => #{data_dir => data_dir()},
        vectordb => #{db_path => vector_data_dir()},
        embedding => #{
            fields => [],
            mode => sync,
            embedder => embedder(),
            dimensions => configured_dim(),
            metadata_fields => [<<"source_path">>, <<"header_path">>, <<"kind">>,
                                <<"start_line">>, <<"end_line">>, <<"type">>,
                                <<"topics">>]
        }
    }).

data_dir() ->
    application:get_env(mcl_rag, data_dir, "/var/lib/mcl-rag/data").

vector_data_dir() ->
    filename:join(data_dir(), "vectors").

configured_dim() ->
    application:get_env(mcl_rag, embed_dim, ?DEFAULT_DIM).

%% Provider selection. Defaults to `ollama' (a laptop/dev convenience --
%% see config/dev.config), so a local run needs nothing extra. Fleet
%% deployment sets `embed_provider = mcl_embedder' (config/sys.config.src):
%% the beam Celerons have no AVX2, so embedding runs on mcl-embedder,
%% reached over the mesh, not locally -- see rag_embed_mcl_embedder.
embedder() ->
    case application:get_env(mcl_rag, embed_provider, ollama) of
        mcl_embedder ->
            {rag_embed_mcl_embedder, #{dimension => configured_dim()}};
        ollama ->
            Url = application:get_env(mcl_rag, embed_url, <<"http://127.0.0.1:11434">>),
            Model = application:get_env(mcl_rag, embed_model, <<"nomic-embed-text">>),
            {ollama, #{url => to_bin(Url), model => to_bin(Model)}}
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L)   -> list_to_binary(L).

%%% Internals — chunks

%% `Meta' may arrive shaped like a `markdown_chunker' chunk (atom keys,
%% an atom `kind' of `prose'/`code') — that is this store's one caller-
%% facing convenience, not something every caller should have to
%% pre-normalize. barrel documents are JSON-shaped: everything becomes a
%% binary key, and the one known atom-valued field (`kind') becomes a
%% binary value too, or the doc would end up with both an atom and a
%% binary variant of the same field.
put_chunk_doc(Db, Id, Content, Meta) ->
    Shaped = json_shape(Meta),
    Doc = Shaped#{<<"id">> => Id, <<"content">> => Content},
    normalize_write(put_doc_upsert(Db, Id, Doc)).

%% Write a chunk with a pre-computed embedding. The `<<"_embedding">>'
%% field is recognized by barrel as a client-supplied vector
%% (`EMBEDDING_SRC_CLIENT'), so barrel indexes it synchronously without
%% calling the embedder — a fast barrel write + HNSW insert, no mesh call.
put_chunk_with_vector_doc(Db, Id, Content, Meta, Vector) ->
    Shaped = json_shape(Meta),
    Doc = Shaped#{<<"id">> => Id, <<"content">> => Content,
                  <<"_embedding">> => Vector},
    normalize_write(put_doc_upsert(Db, Id, Doc)).

%% barrel requires the current `_rev' on the Doc map to update an
%% existing document -- a blind put_doc (no _rev) on an id that
%% already exists is rejected as {error, conflict}, not silently
%% overwritten (see barrel_docdb's own put_doc/2,3 doc comment: "for
%% updates, the document must include the current _rev value").
%%
%% A conflict here is a real "fetch the current _rev and retry", not
%% "already correct, nothing to do": chunk_id is position-derived
%% (source_path|header_path|start_line, see markdown_chunker.erl), not
%% content-derived, so the SAME id can legitimately need DIFFERENT
%% content on a genuine re-ingest -- treating conflict as a silent
%% success would leave stale content indexed. Found live re-running
%% seed_corpus against hecate-corpus: every one of ~500+ chunks from
%% the first run reported conflict on the second, and without this fix
%% every one of those would have been silently skipped rather than
%% actually re-written.
put_doc_upsert(Db, Id, Doc) ->
    case barrel:put_doc(Db, Doc) of
        {error, conflict} -> put_doc_with_current_rev(Db, Id, Doc);
        Result            -> Result
    end.

put_doc_with_current_rev(Db, Id, Doc) ->
    case barrel:get_doc(Db, Id) of
        {ok, #{<<"_rev">> := Rev}} -> barrel:put_doc(Db, Doc#{<<"_rev">> => Rev});
        {error, _} = E             -> E
    end.

%% Merge `Topics' into an existing chunk document's metadata: read the
%% current doc (for its `_rev'), add `<<"topics">>', write back --
%% carrying the chunk's stored vector explicitly.
%%
%% barrel does NOT return `<<"_embedding">>' on a read: the vector lives
%% in its own column and the read-back body has no trace of it. A doc
%% re-put without one, under a policy with `fields => []', matches no
%% embedding rule, so barrel DEINDEXES it -- the chunk stays in the
%% document store and silently leaves the vector index. Verified against
%% barrel directly (2026-09-02): put with a vector, search finds it,
%% get_doc + put_doc of that same body, search finds nothing. So the
%% vector is read back separately (`barrel:vector_get/2') and put on the
%% doc, which restores the index entry and refreshes its metadata.
%%
%% Live effect while this was broken: `classify_topics' and
%% `add_knowledge''s `topics' both silently removed every chunk they
%% tagged from semantic search.
tag_chunk_doc(Db, ChunkId, Topics) ->
    tag_chunk_doc(Db, ChunkId, Topics, barrel:get_doc(Db, ChunkId)).

tag_chunk_doc(Db, ChunkId, Topics, {ok, Doc}) ->
    Updated = with_stored_vector(Db, ChunkId, Doc#{<<"topics">> => Topics}),
    normalize_write(put_doc_upsert(Db, ChunkId, Updated));
tag_chunk_doc(_Db, _ChunkId, _Topics, {error, _} = E) ->
    E.

%% A chunk with no vector entry (written by `put_chunk/3') has nothing
%% to preserve -- it was never in the index and stays out of it.
with_stored_vector(Db, ChunkId, Doc) ->
    case barrel:vector_get(Db, ChunkId) of
        {ok, #{vector := Vector}} when is_list(Vector) -> Doc#{<<"_embedding">> => Vector};
        _NoVector                                      -> Doc
    end.

json_shape(Map) ->
    maps:fold(fun(K, V, Acc) -> Acc#{json_key(K) => json_value(V)} end, #{}, Map).

json_key(K) when is_atom(K)   -> atom_to_binary(K, utf8);
json_key(K) when is_binary(K) -> K.

json_value(V) when is_atom(V), V =/= true, V =/= false, V =/= undefined ->
    atom_to_binary(V, utf8);
json_value(V) -> V.

normalize_write({ok, _RevInfo}) -> ok;
normalize_write({error, _} = E) -> E.

chunk_from_doc({ok, #{<<"id">> := Id, <<"content">> := Content} = Doc}) ->
    {ok, #{chunk_id => Id, content => Content, meta => chunk_meta(Doc)}};
chunk_from_doc(_NotFound) ->
    {error, not_found}.

chunk_meta(Doc) ->
    maps:without([<<"id">>, <<"content">>, <<"_embedding">>, <<"_rev">>, <<"type">>], Doc).

chunk_count(Db) ->
    case barrel:vector_stats(Db) of
        {ok, #{count := N}} -> N;
        _                   -> 0
    end.

to_hits(Db, {ok, RawHits}) ->
    {ok, [hit(Db, H) || H <- RawHits]};
to_hits(_Db, {error, _} = E) ->
    E.

%% barrel's vector store only carries text for vectors IT embedded.
%% Every vector here is client-supplied (`_embedding', see
%% put_chunk_with_vector_doc/5) under a policy with `fields => []', so
%% a hit's `text' is empty or absent -- the chunk's content lives on
%% the docdb side under the same id, and that is where a hit reads it
%% from. Found live (2026-09-02): every search hit reached macula-cli
%% with an empty `content'.
hit(Db, #{key := Id, score := Score} = Raw) ->
    Meta = maps:get(metadata, Raw, #{}),
    #{chunk_id    => Id,
      content     => hit_content(Db, Id, maps:get(text, Raw, <<>>)),
      score       => Score,
      source_path => maps:get(<<"source_path">>, Meta, <<>>),
      meta        => maps:without([<<"source_path">>], Meta)}.

hit_content(_Db, _Id, Text) when byte_size(Text) > 0 ->
    Text;
hit_content(Db, Id, _Empty) ->
    stored_content(barrel:get_doc(Db, Id)).

stored_content({ok, #{<<"content">> := Content}}) -> Content;
stored_content(_NotFound)                          -> <<>>.

%%% Internals — sources

source_id(DocumentId) -> <<?SOURCE_ID_PREFIX, DocumentId/binary>>.

put_source_doc(Db, #{document_id := Id} = Source) ->
    SourceDocId = source_id(Id),
    Doc = #{
        <<"id">>           => SourceDocId,
        <<"type">>         => <<"source">>,
        <<"document_id">>  => Id,
        <<"source_path">>  => maps:get(source_path, Source, <<>>),
        <<"source_type">>  => maps:get(source_type, Source, <<>>),
        <<"raw_bytes">>    => maps:get(raw_bytes, Source, <<>>),
        <<"deposited_by">> => maps:get(deposited_by, Source, <<>>)
    },
    normalize_write(put_doc_upsert(Db, SourceDocId, Doc)).

source_from_doc({ok, #{<<"type">> := <<"source">>} = Doc}) ->
    {ok, source_row(Doc)};
source_from_doc(_NotFoundOrNotASource) ->
    {error, not_found}.

%% `deposited_by' is omitted when empty (an older source predating this
%% field, or a genuinely uncalled deposit) rather than returned as
%% `<<>>' -- an absent key is what every other optional field here
%% already means "nothing to report", and callers checking `maps:is_key'
%% or `maps:get(deposited_by, Row, undefined)' get the answer they'd
%% expect either way.
source_row(Doc) ->
    omit_empty(deposited_by, maps:get(<<"deposited_by">>, Doc, <<>>),
        #{document_id => maps:get(<<"document_id">>, Doc),
          source_path => maps:get(<<"source_path">>, Doc, <<>>),
          source_type => maps:get(<<"source_type">>, Doc, <<>>)}).

omit_empty(_Key, <<>>, Row) -> Row;
omit_empty(Key, Value, Row) -> Row#{Key => Value}.

source_content_from_doc({ok, #{<<"type">> := <<"source">>} = Doc}) ->
    {ok, #{source_path => maps:get(<<"source_path">>, Doc, <<>>),
           raw_bytes   => maps:get(<<"raw_bytes">>, Doc, <<>>)}};
source_content_from_doc(_NotFoundOrNotASource) ->
    {error, not_found}.

%% `barrel:find/3' results are not flat documents: each entry is
%% `#{<<"id">> => Id, <<"doc">> => ActualDoc}' (plus whatever else the
%% query's projection carries) — unwrap before treating it as a document.
find_doc(#{<<"doc">> := Doc}) -> Doc;
find_doc(Doc)                 -> Doc.

%% barrel's `find' has NO `offset' option -- `OFFSET' is a BQL keyword,
%% not a find/3 option, and passing one does not merely get ignored: the
%% query comes back EMPTY. Found live (2026-09-02): every page after the
%% first returned zero rows, so a store with more than one page of
%% sources was silently unlistable past its first `Limit', and a sweep
%% that paged through the sources saw only the first page and reported
%% itself complete.
%%
%% Paging is therefore done here: fetch `Offset + Limit' and drop the
%% first `Offset'. Linear in the offset, which is honest for a corpus of
%% a few hundred documents and the reason `list_sources_page' caps
%% `limit' at 200. barrel's own chunk_size/continuation cursor is the
%% answer if this ever pages through a corpus large enough for that to
%% matter -- it needs a cursor on the wire, not an integer offset.
list_sources_page(Db, Offset, Limit) ->
    Query = #{where => [{path, [<<"type">>], <<"source">>}]},
    case barrel:find(Db, Query, #{limit => Offset + Limit}) of
        {ok, Docs, _Meta} -> {ok, [source_row(find_doc(D)) || D <- drop(Offset, Docs)]};
        {error, _} = E    -> E
    end.

%% lists:nthtail/2 fails when the list is shorter than N; a page past the
%% end is an empty page, not a crash.
drop(0, L)                          -> L;
drop(N, L) when length(L) =< N      -> [];
drop(N, L)                          -> lists:nthtail(N, L).

list_chunks_by_source_page(Db, SourcePath, Limit) ->
    Query = #{where => [{path, [<<"source_path">>], SourcePath}]},
    case barrel:find(Db, Query, #{limit => Limit}) of
        {ok, Docs, _Meta} ->
            {ok, [C || D <- Docs, {ok, C} <- [chunk_from_doc({ok, find_doc(D)})]]};
        {error, _} = E ->
            E
    end.

find_source_by_path_doc(Db, SourcePath) ->
    Query = #{where => [
        {path, [<<"type">>], <<"source">>},
        {path, [<<"source_path">>], SourcePath}
    ]},
    case barrel:find(Db, Query, #{limit => 1}) of
        {ok, [D | _], _Meta} -> {ok, source_row(find_doc(D))};
        {ok, [], _Meta}      -> {error, not_found};
        {error, _} = E       -> E
    end.

%%% Internals — corpus watermarks (detect_corpus_change)

watermark_id(CorpusId, SourcePath) ->
    <<?WATERMARK_ID_PREFIX, CorpusId/binary, $:, SourcePath/binary>>.

put_watermark_doc(Db, CorpusId, SourcePath, DiffHash) ->
    WatermarkId = watermark_id(CorpusId, SourcePath),
    Doc = #{
        <<"id">>          => WatermarkId,
        <<"type">>        => <<"watermark">>,
        <<"corpus_id">>   => CorpusId,
        <<"source_path">> => SourcePath,
        <<"diff_hash">>   => DiffHash
    },
    normalize_write(put_doc_upsert(Db, WatermarkId, Doc)).

watermark_from_doc({ok, #{<<"type">> := <<"watermark">>, <<"diff_hash">> := Hash}}) ->
    {ok, #{diff_hash => Hash}};
watermark_from_doc(_NotFoundOrNotAWatermark) ->
    {error, not_found}.

%%% Internals — re-embed requests (schedule_reembed)

put_reembed_request_doc(Db, #{document_id := DocId} = Req) ->
    RequestId = <<?REEMBED_ID_PREFIX, DocId/binary, $:, (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Doc = #{
        <<"id">>            => RequestId,
        <<"type">>          => <<"reembed_request">>,
        <<"document_id">>   => DocId,
        <<"corpus_id">>     => maps:get(corpus_id, Req, <<>>),
        <<"source_path">>   => maps:get(source_path, Req, <<>>),
        <<"priority">>      => maps:get(priority, Req, <<>>),
        <<"scheduled_at">>  => maps:get(scheduled_at, Req, <<>>),
        <<"status">>        => <<"pending">>
    },
    case normalize_write(barrel:put_doc(Db, Doc)) of
        ok             -> {ok, #{request_id => RequestId}};
        {error, _} = E -> E
    end.
