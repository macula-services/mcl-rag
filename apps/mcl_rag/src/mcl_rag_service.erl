%% @doc The mcl_om service contract for mcl-rag: the mesh's shared memory.
%%
%% Retrieval over a realm-bound corpus, and the deposits agents remember into
%% it, served as seventeen org-namespaced procedures under `mcl-rag'. Its data
%% is one barrel database, `rag_chunks' (documents and vectors), under the
%% data dir. A store migrated from the predecessor service opens as it is.
%%
%% SIX CALLBACKS, ALL REQUIRED. mcl_om resolves them BY NAME at startup, so the
%% `-behaviour' attribute below turns a missing one into a compile error.
-module(mcl_rag_service).

-behaviour(mcl_om_service).

-export([info/0, start/1, stop/1, health/0, capabilities/0, identity_spec/0]).

info() ->
    #{name => <<"mcl-rag">>,
      version => <<"0.1.0">>,
      description => <<"The mesh shared memory: retrieval over a realm-bound corpus, and the deposits agents remember into it">>}.

%% The operator list is checked before anything starts: a malformed one would
%% otherwise surface on the first destructive call, as a crash in the gate.
start(_Opts) ->
    ok = operators_checked(rag_operators:parse(application:get_env(mcl_rag, operators, undefined))),
    mcl_rag_sup:start_link().

operators_checked({ok, _Operators}) -> ok;
operators_checked({error, Reason})  -> error({invalid_rag_operators, Reason}).

stop(_State) -> ok.

%% The service's own verdict: its store first, then whether the org can reach
%% this shard. Opening the store rebuilds the vector index, minutes on the
%% production corpus, and every call is refused with `{error, store_opening}'
%% meanwhile. The federated procedure is macula_rag's, not one of the
%% seventeen, so mcl_om's provider_grants never lists it: join_federation
%% reports its grant here. Whether callers can REACH each of the seventeen
%% (its D25 provider grant) is reported by mcl_om's /health itself, combined
%% with this verdict.
health() ->
    store_health(whereis(rag_store)).

store_health(undefined) -> {down, store_not_running};
store_health(_Pid)      -> opened(rag_store:status()).

opened(open)    -> join_federation:health();
opened(opening) -> {degraded, store_opening}.

%% The seventeen procedures, registered by mcl_om as `mcl-rag/<name>' (the org
%% comes from config). Each goes through mcl_om's simple handler into
%% mcl_rag_mesh_rpc's handler of the same name.
%%
%% ⚠ EIGHT ARE OPERATOR-ONLY: every procedure that deletes, replaces or
%% rewrites what the store holds (rag_operators:operator_only/0) refuses a
%% caller whose verified node id is not in `operators'. Queries and
%% add_knowledge stay open to any caller the station admits.
capabilities() ->
    [cap(Name) || Name <- [<<"ingest_document">>, <<"embed_document">>,
                           <<"upload_knowledge">>, <<"add_knowledge">>,
                           <<"classify_topics">>, <<"prune_chunks">>,
                           <<"retire_document">>, <<"answer_query">>,
                           <<"rerank_results">>, <<"get_chunk_by_id">>,
                           <<"search_chunks_semantic">>, <<"list_chunks_by_source">>,
                           <<"get_source_by_id">>, <<"list_sources_page">>,
                           <<"get_document_verbatim">>, <<"detect_corpus_change">>,
                           <<"schedule_reembed">>]].

cap(Name) ->
    #{name => Name, version => 1,
      handler => {mcl_om_simple_handler,
                  {mcl_rag_mesh_rpc, binary_to_atom(<<"handle_", Name/binary>>)}}}.

%% THE AUTHORITY THIS SERVICE ASKS THE REALM FOR, and deliberately nothing more.
%% Ask for exactly the topics you publish and subscribe to. Popped, an attacker
%% gains precisely this and no more, which is the whole point of listing it.
%%
%% The scope is claimed now because it is the namespace every later resource
%% hangs under, and a scope costs nothing while a rename costs every deployed
%% peer.
identity_spec() ->
    #{scope => <<"mcl-rag">>,
      actions => [],
      resources => [],
      ttl_days => 30}.
