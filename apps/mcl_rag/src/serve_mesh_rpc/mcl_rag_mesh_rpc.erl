%%% @doc The actual request-handling logic for every capability
%%% `mcl_rag_service:capabilities/0` advertises.
%%%
%%% Production traffic to mcl-rag flows over the mesh. A plugin
%%% on a user laptop calls:
%%%
%%%   macula:call(LocalPool, Realm,
%%%               <<"mcl-rag.answer_query">>, Params, Timeout).
%%%
%%% Advertising and dispatch both go through the standard
%%% `mcl_om:boot/1` → `mcl_om_capabilities:register/1` path, using
%%% `mcl_rag_service:capabilities/0''s own `handler' key on each
%%% capability (`{mcl_om_simple_handler, {?MODULE, HandlerFun}}`) —
%%% this module no longer advertises anything itself. Each `handle_*/1'
%%% function here is that `HandlerFun', invoked by
%%% `mcl_om_simple_handler' on an inbound call; `route/2' is the
%%% shared method → slice-handler dispatch every `handle_*/1' goes
%%% through.
%%%
%%% `dispatch/2' is a test/debug entry point that bypasses the mesh
%%% entirely, used by this repo's own test suites.
-module(mcl_rag_mesh_rpc).
-behaviour(gen_server).

-export([
    start_link/0,
    dispatch/2,
    %% Handlers — invoked by the SDK on inbound RPC. One per capability.
    handle_ingest_document/1,
    handle_embed_document/1,
    handle_upload_knowledge/1,
    handle_add_knowledge/1,
    handle_classify_topics/1,
    handle_prune_chunks/1,
    handle_retire_document/1,
    handle_answer_query/1,
    handle_rerank_results/1,
    handle_get_chunk_by_id/1,
    handle_search_chunks_semantic/1,
    handle_list_chunks_by_source/1,
    handle_get_source_by_id/1,
    handle_list_sources_page/1,
    handle_get_document_verbatim/1,
    handle_detect_corpus_change/1,
    handle_schedule_reembed/1
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Test/debug entry point that bypasses the SDK and dispatches
%% directly to the matching slice handler.
-spec dispatch(binary(), map()) -> {ok, term()} | {error, term()}.
dispatch(Method, Params) when is_binary(Method), is_map(Params) ->
    gen_server:call(?MODULE, {dispatch, Method, Params}).

%%% gen_server

init([]) ->
    %% Advertising happens via mcl_om:boot/1's own
    %% mcl_om_capabilities:register/1 call -- nothing to do here.
    {ok, #{}}.

handle_call({dispatch, Method, Params}, _From, S) ->
    {reply, route(Method, Params), S};
handle_call(_Msg, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.
handle_info(_Msg, S) -> {noreply, S}.
terminate(_Reason, _State) -> ok.

%%% Internal: SDK handler entry points (one per capability)

handle_ingest_document(P)        -> route(<<"mcl-rag.ingest_document">>, P).
handle_embed_document(P)         -> route(<<"mcl-rag.embed_document">>, P).
handle_upload_knowledge(P)       -> route(<<"mcl-rag.upload_knowledge">>, P).
handle_add_knowledge(P)          -> route(<<"mcl-rag.add_knowledge">>, P).
handle_classify_topics(P)        -> route(<<"mcl-rag.classify_topics">>, P).
handle_prune_chunks(P)           -> route(<<"mcl-rag.prune_chunks">>, P).
handle_retire_document(P)        -> route(<<"mcl-rag.retire_document">>, P).
handle_answer_query(P)           -> route(<<"mcl-rag.answer_query">>, P).
handle_rerank_results(P)         -> route(<<"mcl-rag.rerank_results">>, P).
handle_get_chunk_by_id(P)        -> route(<<"mcl-rag.get_chunk_by_id">>, P).
handle_search_chunks_semantic(P) -> route(<<"mcl-rag.search_chunks_semantic">>, P).
handle_list_chunks_by_source(P)  -> route(<<"mcl-rag.list_chunks_by_source">>, P).
handle_get_source_by_id(P)       -> route(<<"mcl-rag.get_source_by_id">>, P).
handle_list_sources_page(P)      -> route(<<"mcl-rag.list_sources_page">>, P).
handle_get_document_verbatim(P)  -> route(<<"mcl-rag.get_document_verbatim">>, P).
handle_detect_corpus_change(P)   -> route(<<"mcl-rag.detect_corpus_change">>, P).
handle_schedule_reembed(P)       -> route(<<"mcl-rag.schedule_reembed">>, P).

%%% Internal: method → slice handler → mesh wire shape

%% Every string in a reply is prose or an identifier -- a chunk's
%% content, a source path, a document id, a topic -- and a bare binary
%% encodes as a CBOR BYTE string, which macula-cli / macula-mcp / every
%% non-BEAM SDK renders as `0x...' hex (found live on list_sources_page
%% and search_chunks_semantic, 2026-09-02). So an ok reply is walked
%% once here, at the mesh boundary, and every binary in it becomes
%% `{text, Bin}'. Here and not in the desks: the same desks serve HTTP
%% through their `*_api' modules, where jsx wants bare binaries.
%% `get_document_verbatim' is the one exception and shapes itself: its
%% `raw_bytes' really are bytes and must stay so.
route(<<"mcl-rag.get_document_verbatim">> = Method, P) ->
    desk(Method, P);
route(Method, P) ->
    as_wire(desk(Method, P)).

as_wire({ok, Value}) -> {ok, text_wire(Value)};
as_wire(Other)       -> Other.

text_wire(M) when is_map(M)    -> maps:map(fun(_K, V) -> text_wire(V) end, M);
text_wire(L) when is_list(L)   -> [text_wire(V) || V <- L];
text_wire(B) when is_binary(B) -> {text, B};
text_wire(V)                   -> V.

desk(<<"mcl-rag.ingest_document">>, P) ->
    maybe_ingest_document:ingest(P);
desk(<<"mcl-rag.embed_document">>, P) ->
    maybe_embed_document:embed(P);
desk(<<"mcl-rag.upload_knowledge">>, P) ->
    maybe_upload_knowledge:upload(P);
desk(<<"mcl-rag.add_knowledge">>, P) ->
    maybe_add_knowledge:add(P);
desk(<<"mcl-rag.classify_topics">>, P) ->
    maybe_classify_topics:classify(P);
desk(<<"mcl-rag.prune_chunks">>, P) ->
    maybe_prune_chunks:prune(P);
desk(<<"mcl-rag.retire_document">>, P) ->
    maybe_retire_document:retire(P);
desk(<<"mcl-rag.answer_query">>, P) ->
    answer_query_result(maybe_answer_query:retrieve(P));
desk(<<"mcl-rag.rerank_results">>, P) ->
    rerank_result(maybe_rerank_results:rerank(P));
desk(<<"mcl-rag.get_chunk_by_id">>, P) ->
    get_chunk_by_id:handle(mcl_om_wire:field(<<"chunk_id">>, P));
desk(<<"mcl-rag.search_chunks_semantic">>, P) ->
    search_chunks_semantic:handle(P);
desk(<<"mcl-rag.list_chunks_by_source">>, P) ->
    list_chunks_by_source:handle(P);
desk(<<"mcl-rag.get_source_by_id">>, P) ->
    get_source_by_id:handle(mcl_om_wire:field(<<"source_id">>, P));
desk(<<"mcl-rag.list_sources_page">>, P) ->
    list_sources_page:handle(P);
desk(<<"mcl-rag.get_document_verbatim">>, P) ->
    get_document_verbatim:handle(mcl_om_wire:field(<<"source_path">>, P));
desk(<<"mcl-rag.detect_corpus_change">>, P) ->
    maybe_detect_corpus_change:detect(P);
desk(<<"mcl-rag.schedule_reembed">>, P) ->
    maybe_schedule_reembed:schedule(P);
desk(Other, _P) ->
    {error, {unknown_method, Other}}.

%% Both mirror their own HTTP handler's response shape (answer_query_api.erl/
%% rerank_results_api.erl), so a mesh caller and an HTTP caller see the same
%% contract for either.
answer_query_result({ok, Hits})    -> {ok, #{hits => Hits}};
answer_query_result({error, _} = E) -> E.

rerank_result({ok, Hits})    -> {ok, #{hits => Hits}};
rerank_result({error, _} = E) -> E.
