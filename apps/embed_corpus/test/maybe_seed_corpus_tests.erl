%% @doc The async seed refuses what the sync seed would refuse, before it
%% spawns: it used to answer `accepted' for any request and let the worker
%% fail where nobody reads the result.
-module(maybe_seed_corpus_tests).

-include_lib("eunit/include/eunit.hrl").

an_async_seed_without_an_id_is_refused_test() ->
    ?assertMatch({error, _}, maybe_seed_corpus:seed_async(#{<<"root_dir">> => <<"/tmp">>})).

an_async_seed_without_a_root_dir_is_refused_test() ->
    ?assertEqual({error, missing_root_dir},
                 maybe_seed_corpus:seed_async(#{<<"seed_id">> => <<"s1">>})).
