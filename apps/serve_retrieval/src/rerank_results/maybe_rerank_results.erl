%%% @doc Handler for `rerank_results_v1' -- a real hybrid rerank, not a
%%% stub, but a deliberately narrow one: no cross-encoder or other
%%% learned reranking model exists anywhere in this codebase's
%%% dependency chain (barrel's own Ollama integration is an embedder,
%%% not a reranker), and standing one up is a real infra decision
%%% (which model, which service, a new dependency) that belongs to
%%% whoever picks `reranker_model', not something to invent silently
%%% here. `reranker_model' is accepted and passed through on each hit
%%% (informational -- a future caller-selectable method), but every
%%% call today reranks the same way:
%%%
%%% Blend each hit's already-computed semantic `score' with a lexical
%%% overlap score against `query_text' (case-insensitive token overlap
%%% between the query and the hit's `content'), then re-sort by the
%%% blend. This is the standard "hybrid search" idea in its simplest
%%% form -- semantic search alone can rank a paraphrase highly even when
%%% it misses an exact term the query cares about (a product code, a
%%% proper noun); a lexical signal pulls exact-term matches back up
%%% without needing a second model call. `?SEMANTIC_WEIGHT' favors the
%%% existing semantic score (0.65) since it already reflects real
%%% embedding similarity, not a heuristic -- lexical overlap is a
%%% correction, not the primary signal.
-module(maybe_rerank_results).

-export([rerank/1]).

%% Weight given to the ALREADY-COMPUTED semantic `score' in the blend;
%% the remainder goes to lexical overlap. Not caller-configurable today
%% -- see this module's own doc comment on why `reranker_model' doesn't
%% select between methods yet.
-define(SEMANTIC_WEIGHT, 0.65).

-spec rerank(map()) -> {ok, [map()]} | {error, term()}.
rerank(Params) when is_map(Params) ->
    case rerank_results_v1:from_map(Params) of
        {ok, Cmd}      -> rerank_cmd(Cmd);
        {error, _} = E -> E
    end.

rerank_cmd(Cmd) ->
    case rerank_results_v1:validate(Cmd) of
        ok         -> do_rerank(Cmd);
        {error, R} -> {error, R}
    end.

do_rerank(Cmd) ->
    QueryTokens = tokenize(rerank_results_v1:get_query_text(Cmd)),
    Model = rerank_results_v1:get_reranker_model(Cmd),
    Scored = [score_hit(H, QueryTokens, Model) || H <- rerank_results_v1:get_hits(Cmd)],
    Sorted = lists:reverse(lists:keysort(1, Scored)),
    {ok, [Hit || {_RerankScore, Hit} <- Sorted]}.

%% Sorting on a {RerankScore, Hit} pair with `lists:keysort/2' (ascending)
%% then reversing is simpler than a custom descending comparator, and
%% ties break on Erlang's own term order for the second element --
%% stable enough for this, no ordering guarantee promised beyond score.
%% The {Score, Hit} pair is only a sort key, stripped back down to just
%% Hit in do_rerank/1 above -- a raw tuple isn't a JSON value, jsx
%% crashes trying to encode one directly (found live: `badarg` in
%% jsx_encoder:unzip/2 the first time this returned the pair itself).
%%
%% `Hit' arrives from a JSON body, so its OWN fields are binary-keyed
%% (`<<"score">>', `<<"content">>' -- the same shape `search_chunks_semantic'
%% put on the wire when whatever this hit came from was JSON-encoded, see
%% rag_store:hit/1). The fields THIS function adds use atom keys, matching
%% every other handler's own output shape in this codebase -- both key
%% types coexist fine in one map; jsx encodes either to a JSON string key.
score_hit(Hit, QueryTokens, Model) ->
    Semantic = maps:get(<<"score">>, Hit, 0.0),
    Lexical = lexical_overlap(QueryTokens, tokenize(maps:get(<<"content">>, Hit, <<>>))),
    RerankScore = ?SEMANTIC_WEIGHT * Semantic + (1 - ?SEMANTIC_WEIGHT) * Lexical,
    {RerankScore, Hit#{
        rerank_score => RerankScore,
        semantic_score => Semantic,
        lexical_score => Lexical,
        reranker_model => json_null_for_undefined(Model)
    }}.

%% jsx encodes an arbitrary atom as its own name (`undefined' -> the
%% JSON STRING "undefined"), not JSON null -- an omitted, genuinely
%% absent `reranker_model' should read back as absent (null), not as
%% the word "undefined" masquerading as a real value.
json_null_for_undefined(undefined) -> null;
json_null_for_undefined(Model)     -> Model.

%% Lowercase, split on anything that isn't a letter or digit, drop empty
%% tokens -- deliberately simple (no stemming, no stopword list): this
%% blend only needs "does the hit mention what the query mentions," not
%% a full IR pipeline.
tokenize(undefined) -> [];
tokenize(Text) when is_binary(Text) ->
    Lower = string:lowercase(Text),
    Parts = re:split(Lower, "[^\\p{L}\\p{N}]+", [{return, binary}, unicode]),
    [P || P <- Parts, P =/= <<>>].

%% Fraction of the query's own tokens (deduped) that also appear in the
%% hit -- a recall-style overlap, so a longer hit doesn't automatically
%% score higher just for containing more distinct words. Empty query
%% tokens (a query that tokenized to nothing) can't overlap with
%% anything -- 0.0, not a division by zero.
lexical_overlap([], _HitTokens) ->
    0.0;
lexical_overlap(QueryTokens, HitTokens) ->
    QuerySet = lists:usort(QueryTokens),
    HitSet = sets:from_list(HitTokens, [{version, 2}]),
    Matched = length([T || T <- QuerySet, sets:is_element(T, HitSet)]),
    Matched / length(QuerySet).
