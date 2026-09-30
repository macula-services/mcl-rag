%%% @doc A supplied query_vector must have the store's dimension. One of
%%% another length was searched as given against 384-dim vectors; now it is
%%% refused before the store is touched, naming both numbers. The store and
%%% the embedder take the dimension from one place, rag_embedder:dimension/0,
%%% whose default is 384 (the store's own default used to be 768).
-module(query_vector_dimension_tests).

-include_lib("eunit/include/eunit.hrl").

a_vector_of_another_length_is_refused_test() ->
    with_dim(384, fun() ->
        ?assertEqual({error, {dimension_mismatch, 384, 768}},
                     search_chunks_semantic:handle(#{<<"query_vector">> => floats(768)}))
    end).

the_refusal_reaches_answer_query_and_the_wire_shape_test() ->
    with_dim(384, fun() ->
        ?assertEqual({error, {dimension_mismatch, 384, 3}},
                     maybe_answer_query:retrieve(#{query_vector => floats(3), top_k => 5}))
    end).

the_store_and_the_embedder_share_one_dimension_test() ->
    with_dim(unset, fun() ->
        ?assertEqual(384, rag_embedder:dimension()),
        ?assertEqual(rag_embedder:dimension(), rag_store:dimension())
    end),
    with_dim(512, fun() -> ?assertEqual(512, rag_store:dimension()) end).

%%% Internals

floats(N) -> [0.5 || _ <- lists:seq(1, N)].

with_dim(Dim, Fun) ->
    Before = application:get_env(mcl_rag, embed_dim),
    set_dim(Dim),
    try Fun() after restore(Before) end.

set_dim(unset) -> application:unset_env(mcl_rag, embed_dim);
set_dim(Dim)   -> application:set_env(mcl_rag, embed_dim, Dim).

restore(undefined)  -> application:unset_env(mcl_rag, embed_dim);
restore({ok, Dim})  -> application:set_env(mcl_rag, embed_dim, Dim).
