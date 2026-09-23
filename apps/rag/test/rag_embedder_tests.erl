%%% @doc Which embedder rag uses, from `embed_provider'.
-module(rag_embedder_tests).

-include_lib("eunit/include/eunit.hrl").

%% Any barrel_embed_provider module can be named directly, which is how the
%% suites run the pipeline on a deterministic embedder instead of skipping.
a_named_provider_module_is_used_test() ->
    with_provider({rag_embed_stub, #{dimension => 384}}, fun() ->
        {ok, V} = rag_embedder:embed(<<"hello">>),
        ?assertEqual(384, length(V)),
        ?assertEqual({ok, V}, rag_embedder:embed(<<"hello">>)),
        ?assertNotEqual({ok, V}, rag_embedder:embed(<<"other">>)),
        ?assertEqual({rag_embed_stub, #{dimension => 384}}, rag_embedder:provider())
    end).

mcl_embedder_is_the_mesh_client_test() ->
    with_provider(mcl_embedder, fun() ->
        ?assertMatch({rag_embed_mcl_embedder, #{dimension := _}}, rag_embedder:provider())
    end).

with_provider(Provider, Test) ->
    ok = application:set_env(mcl_rag, embed_provider, Provider),
    try Test()
    after application:unset_env(mcl_rag, embed_provider)
    end.
