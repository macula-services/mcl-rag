%%% @doc How mcl-rag asks mcl-embedder for vectors.
%%%
%%% Two things are contract here. The procedure is `mcl-embedder/embed'. And
%%% the kind is `raw': every vector already in the store was made from raw
%%% text, and a query embedded with the model's `query:' prefix would not be
%%% comparable with them.
-module(rag_embed_mcl_embedder_tests).

-include_lib("eunit/include/eunit.hrl").

one_text_asks_mcl_embedder_for_a_raw_vector_test() ->
    with_embedder(fun(_) -> {ok, #{vector => [0.1, 0.2]}} end, fun() ->
        ?assertEqual({ok, [0.1, 0.2]}, rag_embed_mcl_embedder:embed(<<"hello">>, config())),
        ?assertEqual([{<<"mcl-embedder">>, <<"embed">>, #{text => <<"hello">>, kind => <<"raw">>}}],
                     calls())
    end).

many_texts_get_many_vectors_test() ->
    with_embedder(fun(_) -> {ok, #{vectors => [[0.1], [0.2]]}} end, fun() ->
        ?assertEqual({ok, [[0.1], [0.2]]},
                     rag_embed_mcl_embedder:embed_batch([<<"a">>, <<"b">>], config())),
        ?assertMatch([{_, _, #{texts := [<<"a">>, <<"b">>]}}], calls())
    end).

%% macula hands a key over as an atom only when it exists, otherwise as text.
a_reply_under_any_key_form_is_read_test() ->
    with_embedder(fun(_) -> {ok, #{{text, <<"vector">>} => [0.5]}} end, fun() ->
        ?assertEqual({ok, [0.5]}, rag_embed_mcl_embedder:embed(<<"x">>, config()))
    end).

a_reply_without_a_vector_is_an_error_test() ->
    with_embedder(fun(_) -> {ok, #{something => other}} end, fun() ->
        ?assertMatch({error, {invalid_response, _}}, rag_embed_mcl_embedder:embed(<<"x">>, config()))
    end).

a_failed_call_is_passed_on_test() ->
    with_embedder(fun(_) -> {error, no_provider} end, fun() ->
        ?assertEqual({error, no_provider}, rag_embed_mcl_embedder:embed(<<"x">>, config()))
    end).

%% --- helpers ---

config() -> #{dimension => 384, timeout => 1000}.

with_embedder(Reply, Test) ->
    ok = meck:new(mcl_om, [non_strict]),
    ok = meck:expect(mcl_om, call_capability,
                     fun(Org, Name, Payload, _Timeout) ->
                             self() ! {called, Org, Name, Payload},
                             Reply(Payload)
                     end),
    try Test()
    after meck:unload(mcl_om)
    end.

calls() ->
    receive {called, O, N, P} -> [{O, N, P} | calls()]
    after 0 -> []
    end.
