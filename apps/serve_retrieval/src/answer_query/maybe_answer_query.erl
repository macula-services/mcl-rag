%%% @doc Handler for `answer_query`. A pure read: delegates to
%%% `search_chunks_semantic', which embeds the query text (or takes an
%%% already-computed vector) and searches `rag_store'.
%%%
%%% Previously this desk also produced a `query_answered_v1' event, "an
%%% audit trail of what was asked and what came back" — its own HTTP
%%% handler dispatched it via a nonexistent `evoq:dispatch/4' and had
%%% never once worked. A read query is not a domain fact; nothing here
%%% decided anything worth remembering. Deleted along with `answer_query_v1'
%%% (the command struct existed only to carry a `query_id' the real
%%% retrieval path never used).
-module(maybe_answer_query).

-export([retrieve/1]).

%% @doc Used by `answer_query_api' (local HTTP) and by `mcl_rag_mesh_rpc'
%% (the `answer_query' procedure).
-spec retrieve(map()) -> {ok, [map()]} | {error, term()}.
retrieve(Params) when is_map(Params) ->
    search_chunks_semantic:handle(Params).
