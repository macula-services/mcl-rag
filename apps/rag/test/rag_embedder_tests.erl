%%% @doc Which embedder rag uses, from `embed_provider'.
-module(rag_embedder_tests).

-include_lib("eunit/include/eunit.hrl").

-define(STUB, {rag_embed_stub, #{dimension => 384}}).
-define(E5, <<"macula/multilingual-e5-small:f16">>).

%% Any barrel_embed_provider module can be named directly, which is how the
%% suites run the pipeline on a deterministic embedder instead of skipping.
a_named_provider_module_is_used_test() ->
    with_provider({rag_embed_stub, #{dimension => 384}}, fun() ->
        {ok, V} = rag_embedder:embed(query, <<"hello">>),
        ?assertEqual(384, length(V)),
        ?assertEqual({ok, V}, rag_embedder:embed(query, <<"hello">>)),
        ?assertNotEqual({ok, V}, rag_embedder:embed(query, <<"other">>)),
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
    with_env([{embed_provider, ollama}, {embed_model, ?E5}], fun() ->
        ?assertMatch({barrel_embed_ollama, #{url := <<"http://127.0.0.1:11434">>}}, rag_embedder:provider())
    end).

%% An unnamed model is refused, never replaced by one ollama happens to have:
%% a stand-in of another dimension would not fit the store's index.
an_unnamed_ollama_model_is_refused_test() ->
    with_env([{embed_provider, ollama}], fun() ->
        ?assertError({no_embed_model, _}, rag_embedder:provider())
    end).

%% e5 is trained on "query: " and "passage: " prefixes, and the measurement
%% (measure/e5_prefixes, 2026-09-29) found them no worse on our corpus, so a
%% stored text is embedded as a passage and a search as a query.
e5_embeds_a_query_and_a_passage_with_their_prefixes_test() ->
    with_env([{embed_provider, ?STUB}, {embed_model, ?E5}], fun() ->
        ?assertEqual(stub(<<"query: where is the realm">>),
                     rag_embedder:embed(query, <<"where is the realm">>)),
        ?assertEqual(stub(<<"passage: The realm grants.">>),
                     rag_embedder:embed(passage, <<"The realm grants.">>)),
        {ok, [A, B]} = rag_embedder:embed_batch(passage, [<<"a">>, <<"b">>]),
        ?assertEqual([stub(<<"passage: a">>), stub(<<"passage: b">>)], [{ok, A}, {ok, B}])
    end).

%% The prefixes belong to the model, not to a setting: macula_rag merges scores
%% between shards that name the same model and dimension, so the model id must
%% fully decide how text becomes a vector.
the_prefixes_follow_the_model_test() ->
    with_env([{embed_provider, ?STUB}], fun() ->
        ?assertEqual(stub(<<"plain">>), rag_embedder:embed(query, <<"plain">>))
    end).

%% A model whose scheme mcl-rag does not know is refused where the provider is
%% decided (at the store's open), never embedded one way or the other on a guess.
a_model_without_a_known_scheme_is_refused_test() ->
    with_env([{embed_provider, ?STUB}, {embed_model, <<"someone/other-model">>}], fun() ->
        ?assertError({unknown_embed_model, <<"someone/other-model">>, _}, rag_embedder:provider())
    end),
    with_env([{embed_provider, ollama}, {embed_model, <<"someone/other-model">>}], fun() ->
        ?assertError({unknown_embed_model, <<"someone/other-model">>, _}, rag_embedder:provider())
    end).

stub(Text) -> rag_embed_stub:embed(Text, #{dimension => 384}).

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
