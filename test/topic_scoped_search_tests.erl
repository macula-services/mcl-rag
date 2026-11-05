%%% @doc A topic-scoped search returns the best tagged chunks, however the rest
%%% of the store ranks (mcl-rag#42).
%%%
%%% The topic filter used to run on the vector index's answer: `top_k * 3'
%%% candidates (times the store's own overfetch) out of the whole store, then
%%% the tagged ones kept. A few tagged deposits beside a corpus that sits
%%% closer to the query were never among those candidates, so the search came
%%% back empty. Here 300 untagged chunks sit right next to the query and three
%%% tagged ones further off; the search scoped to their topic must return the
%%% three, through the query desk a mesh caller reaches.
-module(topic_scoped_search_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DIM, 384).
-define(UNTAGGED, 300).
-define(PROVIDER, {rag_embed_stub, #{dimension => ?DIM}}).

tagged_chunks_outranked_by_the_corpus_are_found_test_() ->
    {timeout, 180, fun() ->
        with_store(fun() ->
            ok = put_untagged(?UNTAGGED),
            ok = put_tagged([<<"crew-1">>, <<"crew-2">>, <<"crew-3">>], [<<" Crew:Harbor ">>]),
            ok = put_tagged([<<"other-1">>], [<<"crew:elsewhere">>]),

            %% The whole store: the untagged chunks are the nearest.
            {ok, Whole} = search(#{}),
            ?assertEqual([], [Id || Id <- ids(Whole), not is_untagged(Id)]),

            %% Scoped to the topic, case-blind: exactly the tagged three, best
            %% first, and nothing tagged with another topic.
            {ok, Scoped} = search(#{<<"topics">> => [<<"crew:harbor">>]}),
            ?assertEqual([<<"crew-1">>, <<"crew-2">>, <<"crew-3">>], ids(Scoped)),
            ?assertEqual([[<<"crew:harbor">>]],
                         lists:usort([maps:get(<<"topics">>, maps:get(meta, H)) || H <- Scoped])),

            %% Two topics: the chunks of either.
            {ok, Either} = search(#{<<"topics">> => [<<"crew:harbor">>, <<"CREW:ELSEWHERE">>],
                                    <<"top_k">> => 10}),
            ?assertEqual([<<"crew-1">>, <<"crew-2">>, <<"crew-3">>, <<"other-1">>],
                         lists:sort(ids(Either))),

            %% A topic nobody tagged: nothing, not the nearest untagged text.
            ?assertEqual({ok, []}, search(#{<<"topics">> => [<<"crew:nobody">>]}))
        end)
    end}.

%%------------------------------------------------------------------------------
%% helpers
%%------------------------------------------------------------------------------

search(Extra) ->
    search_chunks_semantic:handle(maps:merge(#{<<"query_vector">> => query(),
                                               <<"top_k">> => 3}, Extra)).

ids(Hits) -> [maps:get(chunk_id, H) || H <- Hits].

is_untagged(<<"near-", _/binary>>) -> true;
is_untagged(_)                     -> false.

%% The query points along the first axis.
query() -> axis_vector(1, 1.0, []).

%% Untagged chunks a hair off the query: cosine close to 1.
put_untagged(N) ->
    lists:foreach(
      fun(I) ->
          Id = list_to_binary(io_lib:format("near-~3..0B", [I])),
          ok = rag_store:put_chunk_with_vector(Id, <<"near text ", Id/binary>>,
                                               #{source_path => <<"corpus/near.md">>},
                                               axis_vector(1, 1.0, [{2 + I, 0.001}]))
      end, lists:seq(1, N)),
    ok.

%% Tagged chunks well off the query, each a little further than the one
%% before, so their order is known: cosine about 0.45 and falling.
put_tagged(Ids, Topics) ->
    lists:foreach(
      fun({J, Id}) ->
          ok = rag_store:put_chunk_with_vector(Id, <<"tagged text ", Id/binary>>,
                                               #{source_path => <<"deposits/", Id/binary>>},
                                               axis_vector(1, 0.5, [{350 + J, 1.0 + J * 0.1}])),
          ok = rag_store:tag_chunk(Id, Topics)
      end, lists:enumerate(Ids)),
    ok.

%% A ?DIM vector: `Lead' on axis `Axis', the given others, zero elsewhere.
axis_vector(Axis, Lead, Others) ->
    Set = maps:from_list([{Axis, Lead} | Others]),
    [maps:get(I, Set, 0.0) || I <- lists:seq(1, ?DIM)].

%% The store as the node runs it (rag_sup under the `rag' application), on a
%% scratch directory removed afterwards, with the stub embedder.
with_store(Test) ->
    Dir = scratch_dir(),
    ok = application:set_env(mcl_rag, data_dir, Dir),
    Was = application:get_env(mcl_rag, embed_provider),
    ok = application:set_env(mcl_rag, embed_provider, ?PROVIDER),
    {ok, _} = application:ensure_all_started(rag),
    try
        ok = await_open(600),
        Test()
    after
        _ = application:stop(rag),
        application:unset_env(mcl_rag, data_dir),
        restore_provider(Was),
        file:del_dir_r(Dir)
    end.

restore_provider({ok, P}) -> application:set_env(mcl_rag, embed_provider, P);
restore_provider(undefined) -> application:unset_env(mcl_rag, embed_provider).

await_open(0) -> {error, store_never_opened};
await_open(N) ->
    case rag_store:status() of
        open    -> ok;
        opening -> timer:sleep(100), await_open(N - 1)
    end.

%% Unique across runs, not only within one VM: a previous run's leftover path
%% must not be reused. with_store/1 removes it.
scratch_dir() ->
    filename:join(os:getenv("TMPDIR", "/tmp"),
                  lists:concat(["topic_scoped_search_", os:getpid(), "_",
                                erlang:system_time(nanosecond)])).
