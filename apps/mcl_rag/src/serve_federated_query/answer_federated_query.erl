%% @doc This shard's answer to the org's federated query
%% (`mcl-rag/rag.query_shard_v1', through macula_rag).
%%
%% The query's text is embedded HERE, with this node's own embedder, and
%% searched in this node's own store. macula_rag has already checked that the
%% asking node names the same embedding, so the scores it merges compare.
%%
%% A hit is `id' (the chunk id) and `score', the contract's minimum, plus the
%% chunk's `content' and `source_path'. A refusal (the store still opening, the
%% embedder unreachable) is the answer: the asking node reports it as this
%% shard's failure.
-module(answer_federated_query).

-export([answer/2]).

-spec answer(map(), #{top_k := pos_integer()}) -> {ok, [map()]} | {error, term()}.
answer(#{<<"text">> := Text}, #{top_k := TopK}) when is_binary(Text), Text =/= <<>> ->
    searched(rag_embedder:embed(Text), TopK);
answer(_Query, _Opts) ->
    {error, missing_text}.

searched({ok, Vector}, TopK)    -> hits(rag_store:search_vector(Vector, TopK));
searched({error, _} = E, _TopK) -> E.

hits({ok, Hits})      -> {ok, [hit(H) || H <- Hits]};
hits({error, _} = E)  -> E.

hit(#{chunk_id := Id, score := Score, content := Content, source_path := Path}) ->
    #{id => Id, score => Score, content => Content, source_path => Path}.
