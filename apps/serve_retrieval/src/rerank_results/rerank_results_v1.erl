%%% @doc Command `rerank_results_v1'.
%%%
%%% Reshaped from the generated stub: the original `original_ranking ::
%%% binary()' field was never a usable shape -- a caller has a LIST of
%%% hits (the exact output of `search_chunks_semantic'/`answer_query':
%%% `chunk_id'/`content'/`score'/`source_path'), not an opaque binary,
%%% and reranking needs the original query text to compute anything new
%%% against. Same kind of correction `answer_query''s own migration
%%% already made to its command (see that module's doc comment) once
%%% the generated stub's guessed shape met a real caller.
-module(rerank_results_v1).
-behaviour(evoq_command).

-export([command_type/0]).
-export([new/1, from_map/1, validate/1, to_map/1]).
-export([stream_id/1]).
-export([get_query_id/1, get_query_text/1, get_hits/1, get_reranker_model/1]).

-record(rerank_results_v1, {
    query_id :: binary() | undefined,
    query_text :: binary() | undefined,
    hits :: [map()] | undefined,
    reranker_model :: binary() | undefined
}).

-opaque t() :: #rerank_results_v1{}.
-export_type([t/0]).

-spec command_type() -> atom().
command_type() -> rerank_results_v1.

-spec new(map()) -> {ok, t()} | {error, term()}.
new(#{query_id := Id} = Params) ->
    {ok, #rerank_results_v1{
        query_id = Id,
        query_text = maps:get(query_text, Params, undefined),
        hits = maps:get(hits, Params, undefined),
        reranker_model = maps:get(reranker_model, Params, undefined)
    }};
new(_) ->
    {error, missing_aggregate_id}.

%% Uses mcl_om_wire:field/2, not a hard #{<<"query_id">> := Id}
%% pattern -- macula's frame decoder atomizes an inbound payload's keys
%% (binary_to_existing_atom), so a hard binary-key match here silently
%% never matches a real mesh caller's payload. See mcl_om_wire's own
%% moduledoc and hecate-corpus's antipatterns skill for the full story.
-spec from_map(map()) -> {ok, t()} | {error, term()}.
from_map(Map) when is_map(Map) ->
    from_map_(mcl_om_wire:field(<<"query_id">>, Map), Map);
from_map(_) ->
    {error, missing_aggregate_id}.

from_map_(undefined, _Map) ->
    {error, missing_aggregate_id};
from_map_(Id, Map) ->
    {ok, #rerank_results_v1{
        query_id = Id,
        query_text = mcl_om_wire:field(<<"query_text">>, Map),
        hits = mcl_om_wire:field(<<"hits">>, Map),
        reranker_model = mcl_om_wire:field(<<"reranker_model">>, Map)
    }}.

%% `query_text'/`hits' are both load-bearing for `maybe_rerank_results'
%% (nothing to score against, and nothing to reorder, without them).
%% `reranker_model' stays optional -- see that module's own doc comment
%% for why it's informational today, not yet a real choice of method.
-spec validate(t()) -> ok | {error, term()}.
validate(#rerank_results_v1{query_id = undefined})    -> {error, missing_aggregate_id};
validate(#rerank_results_v1{query_text = undefined})  -> {error, missing_query_text};
validate(#rerank_results_v1{hits = undefined})         -> {error, missing_hits};
validate(#rerank_results_v1{hits = Hits}) when not is_list(Hits) -> {error, hits_must_be_a_list};
validate(_) -> ok.

-spec to_map(t()) -> map().
to_map(#rerank_results_v1{} = Cmd) ->
    #{
        command_type => rerank_results_v1,
        query_id => Cmd#rerank_results_v1.query_id,
        query_text => Cmd#rerank_results_v1.query_text,
        hits => Cmd#rerank_results_v1.hits,
        reranker_model => Cmd#rerank_results_v1.reranker_model
    }.

-spec stream_id(t()) -> binary().
stream_id(#rerank_results_v1{query_id = Id}) ->
    <<"query-", Id/binary>>.

-spec get_query_id(t()) -> binary() | undefined.
get_query_id(#rerank_results_v1{query_id = V}) -> V.

-spec get_query_text(t()) -> binary() | undefined.
get_query_text(#rerank_results_v1{query_text = V}) -> V.

-spec get_hits(t()) -> [map()] | undefined.
get_hits(#rerank_results_v1{hits = V}) -> V.

-spec get_reranker_model(t()) -> binary() | undefined.
get_reranker_model(#rerank_results_v1{reranker_model = V}) -> V.
