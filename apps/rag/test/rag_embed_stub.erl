%%% @doc A deterministic barrel_embed_provider for tests: the same text always
%%% gets the same unit vector, different texts different ones, and nothing
%%% leaves the node. It stands in for mcl-embedder so the pipeline suites run
%%% instead of skipping. It says nothing about retrieval quality.
-module(rag_embed_stub).
-behaviour(barrel_embed_provider).

-export([embed/2, embed_batch/2, dimension/1, name/0, init/1]).

name() -> rag_embed_stub.

init(Config) -> {ok, Config}.

dimension(Config) -> maps:get(dimension, Config, 384).

embed(Text, Config) when is_binary(Text) ->
    {ok, vector(Text, dimension(Config))}.

embed_batch(Texts, Config) ->
    {ok, [vector(T, dimension(Config)) || T <- Texts]}.

%% SHA-256 stretched over the dimension, centred and L2-normalised.
vector(Text, Dim) ->
    Bytes = stretched(Text, Dim),
    Raw = [(B - 127.5) / 127.5 || <<B>> <= Bytes],
    Norm = math:sqrt(lists:sum([X * X || X <- Raw])),
    [X / Norm || X <- Raw].

stretched(Text, Dim) ->
    binary:part(iolist_to_binary([crypto:hash(sha256, [Text, <<I:32>>])
                                  || I <- lists:seq(0, Dim div 32)]), 0, Dim).
