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

%% What msi00 runs: the node's own ollama, url and model from config, the
%% loopback url when none is set.
ollama_is_the_nodes_own_on_loopback_test() ->
    with_env([{embed_provider, ollama}, {embed_url, <<"http://127.0.0.1:11434">>},
              {embed_model, <<"macula/multilingual-e5-small:f16">>}], fun() ->
        ?assertEqual({barrel_embed_ollama, #{url => <<"http://127.0.0.1:11434">>,
                                             model => <<"macula/multilingual-e5-small:f16">>}},
                     rag_embedder:provider())
    end),
    with_env([{embed_provider, ollama}, {embed_model, <<"m">>}], fun() ->
        ?assertMatch({barrel_embed_ollama, #{url := <<"http://127.0.0.1:11434">>}}, rag_embedder:provider())
    end).

%% An unnamed model is refused, never replaced by one ollama happens to have:
%% a stand-in of another dimension would not fit the store's index.
an_unnamed_ollama_model_is_refused_test() ->
    with_env([{embed_provider, ollama}], fun() ->
        ?assertError({no_embed_model, _}, rag_embedder:provider())
    end).

with_env(Settings, Test) ->
    Was = [{K, application:get_env(mcl_rag, K)} || K <- [embed_provider, embed_url, embed_model]],
    [application:unset_env(mcl_rag, K) || {K, _} <- Was],
    [ok = application:set_env(mcl_rag, K, V) || {K, V} <- Settings],
    try Test()
    after [restore(K, V) || {K, V} <- Was]
    end.

restore(K, undefined) -> application:unset_env(mcl_rag, K);
restore(K, {ok, V})   -> application:set_env(mcl_rag, K, V).

with_provider(Provider, Test) ->
    with_env([{embed_provider, Provider}], Test).
