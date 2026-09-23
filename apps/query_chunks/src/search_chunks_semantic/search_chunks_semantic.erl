%%% @doc Query desk: search_chunks_semantic.
%%%
%%% Takes a query (text OR pre-computed vector) + top_k, returns
%%% the top-k chunk hits enriched with content and source-path.
%%%
%%% Two call shapes accepted:
%%%
%%%   #{<<"query_text">> := Text, <<"top_k">> := N}
%%%       barrel embeds the query itself (record-mode database, see
%%%       rag_store) — no separate embed call needed here.
%%%
%%%   #{<<"query_vector">> := [Float], <<"top_k">> := N}
%%%       use the provided vector directly (caller already embedded)
%%%
%%% Both forms accept an optional `top_k` field, default 10.
%%%
%%% Optional `<<"topics">> := [binary()]` filters results to chunks
%%% tagged with any of the given topics. Over-fetches from the vector
%%% index (3x top_k) then post-filters by topic metadata, returning the
%%% top_k best matches that pass the filter.
-module(search_chunks_semantic).

-export([handle/1]).

-define(DEFAULT_TOP_K, 10).
-define(TOPIC_OVERFETCH_MULTIPLIER, 3).

%% Uses mcl_om_wire:field/2 throughout for PARAMS lookups (query
%% args from the wire), not hard #{<<"...">> := ...} patterns --
%% macula's frame decoder atomizes an inbound payload's keys
%% (binary_to_existing_atom), so a hard binary-key match here silently
%% never matches a real mesh caller's payload. See mcl_om_wire's own
%% moduledoc and hecate-corpus's antipatterns skill for the full story.
%% `has_any_topic/2''s own `Meta'/`Topics' lookups are UNCHANGED -- that
%% map is a stored chunk's own internal metadata from rag_store, never
%% wire input, so it isn't exposed to this hazard.
-spec handle(map()) -> {ok, [map()]} | {error, term()}.
handle(Params) when is_map(Params) ->
    handle_(mcl_om_wire:field(<<"query_vector">>, Params),
           mcl_om_wire:field(<<"query_text">>, Params), Params);
handle(_) ->
    {error, bad_params}.

handle_(V, _Text, Params) when is_list(V) ->
    search_with_topics(Params, fun() -> rag_store:search_vector(V, fetch_k(Params)) end);
handle_(_V, Text, Params) when is_binary(Text) ->
    search_with_topics(Params, fun() -> rag_store:search_text(Text, fetch_k(Params)) end);
handle_(_V, _Text, _Params) ->
    {error, query_text_or_vector_required}.

search_with_topics(Params, SearchFun) ->
    case SearchFun() of
        {ok, Hits} ->
            Filtered = maybe_filter_by_topics(Hits, Params),
            {ok, lists:sublist(Filtered, top_k(Params))};
        {error, _} = E ->
            E
    end.

maybe_filter_by_topics(Hits, Params) ->
    maybe_filter_by_topics_(Hits, mcl_om_wire:field(<<"topics">>, Params)).

maybe_filter_by_topics_(Hits, Topics) when is_list(Topics), Topics =/= [] ->
    TopicSet = sets:from_list([normalize_topic(T) || T <- Topics]),
    [H || H <- Hits, has_any_topic(H, TopicSet)];
maybe_filter_by_topics_(Hits, _Topics) ->
    Hits.

has_any_topic(Hit, TopicSet) ->
    Meta = maps:get(meta, Hit, #{}),
    Topics = maps:get(<<"topics">>, Meta, []),
    ChunkTopics = sets:from_list([normalize_topic(T) || T <- Topics]),
    not sets:is_empty(sets:intersection(TopicSet, ChunkTopics)).

normalize_topic(T) when is_binary(T) -> string:lowercase(string:trim(T));
normalize_topic(T) when is_list(T)   -> normalize_topic(list_to_binary(T)).

%% When filtering by topics, over-fetch from the vector index so the
%% post-filter still has enough candidates to fill top_k. Without a
%% topic filter, fetch exactly top_k.
fetch_k(Params) ->
    fetch_k_(mcl_om_wire:field(<<"topics">>, Params), Params).

fetch_k_(Topics, Params) when is_list(Topics), Topics =/= [] ->
    top_k(Params) * ?TOPIC_OVERFETCH_MULTIPLIER;
fetch_k_(_Topics, Params) ->
    top_k(Params).

top_k(Params) ->
    case mcl_om_wire:field(<<"top_k">>, Params) of
        N when is_integer(N), N > 0, N =< 100 -> N;
        _                                       -> ?DEFAULT_TOP_K
    end.
