%%% @doc Every text mcl-rag stores is embedded as a passage, every search as a
%%% query: the role decides e5's prefix (rag_embedder), so a caller that named
%%% the wrong one would store or search vectors the index was not built for.
-module(rag_embed_roles_tests).

-include_lib("eunit/include/eunit.hrl").

a_stored_chunk_is_embedded_as_a_passage_test() ->
    with_embedder(fun() ->
        {0, [{<<"c1">>, stop}]} =
            rag_chunk_embedder:embed_and_store([#{chunk_id => <<"c1">>, content => <<"text">>}]),
        ?assertEqual(1, meck:num_calls(rag_embedder, embed, [passage, <<"text">>]))
    end).

a_text_search_is_embedded_as_a_query_test() ->
    with_embedder(fun() ->
        ?assertEqual({error, stop}, rag_store:search_text(<<"where">>, 5)),
        ?assertEqual(1, meck:num_calls(rag_embedder, embed, [query, <<"where">>]))
    end).

with_embedder(Test) ->
    ok = meck:new(rag_embedder, [passthrough, no_link]),
    ok = meck:expect(rag_embedder, embed, fun(_Role, _Text) -> {error, stop} end),
    try Test() after meck:unload(rag_embedder) end.
