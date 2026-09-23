%%% @doc detect_corpus_change reports a change as 1 or 0, never a boolean:
%%% its reply crosses the wire (mcl-rag/detect_corpus_change), and the mesh
%%% carries no booleans.
-module(detect_corpus_change_tests).

-include_lib("eunit/include/eunit.hrl").

-define(CMD, #{<<"corpus_id">> => <<"c">>, <<"source_path">> => <<"a.md">>,
               <<"diff_hash">> => <<"h2">>}).

a_path_never_seen_is_changed_test() ->
    with_watermark({error, not_found}, fun() ->
        ?assertMatch({ok, #{changed := 1}}, maybe_detect_corpus_change:detect(?CMD)),
        ?assertEqual(1, meck:num_calls(rag_store, put_watermark, [<<"c">>, <<"a.md">>, <<"h2">>]))
    end).

a_new_hash_is_changed_test() ->
    with_watermark({ok, #{diff_hash => <<"h1">>}}, fun() ->
        ?assertMatch({ok, #{changed := 1}}, maybe_detect_corpus_change:detect(?CMD))
    end).

the_same_hash_is_unchanged_test() ->
    with_watermark({ok, #{diff_hash => <<"h2">>}}, fun() ->
        ?assertMatch({ok, #{changed := 0}}, maybe_detect_corpus_change:detect(?CMD)),
        ?assertEqual(0, meck:num_calls(rag_store, put_watermark, '_'))
    end).

with_watermark(Watermark, Test) ->
    ok = meck:new(rag_store, [no_link]),
    ok = meck:expect(rag_store, get_watermark, fun(_, _) -> Watermark end),
    ok = meck:expect(rag_store, put_watermark, fun(_, _, _) -> ok end),
    try Test() after meck:unload(rag_store) end.
