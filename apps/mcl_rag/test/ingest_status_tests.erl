%% @doc The ingest_status read desk (mcl-rag#8): counts, not content.
%%
%% The scan block is the scheduler's live view and is asserted in
%% refresh_corpus_scheduler_tests; here the repos block is pinned: every
%% listed repo appears, served or not, with its head when it is served and
%% its watermark count.
-module(ingest_status_tests).

-include_lib("eunit/include/eunit.hrl").

status_names_each_listed_repo_test() ->
    ok = meck:new([corpus_repos_config, rag_store], [no_link]),
    ok = meck:expect(corpus_repos_config, read, fun() ->
        {ok, [#{id => <<"a">>, url => <<"u">>, branch => <<"main">>, path => <<"/corpus/a">>},
              #{id => <<"b">>, url => <<"u">>, branch => <<"main">>, path => <<"/corpus/b">>}]}
    end),
    ok = meck:expect(rag_store, served_repos, fun() ->
        {ok, #{<<"a">> => #{commit => <<"c1">>, generation => <<"gen">>}}} end),
    ok = meck:expect(rag_store, watermarked_corpora, fun() -> {ok, [<<"a">>, <<"b">>]} end),
    ok = meck:expect(rag_store, watermarked_paths, fun(Id) ->
        {ok, [<<Id/binary, "/1.md">>, <<Id/binary, "/2.md">>]} end),
    try
        {ok, #{scan := Scan, repos := [A, B]}} = ingest_status:status(),
        ?assert(maps:is_key(state, Scan)),
        ?assertEqual(<<"a">>, maps:get(id, A)),
        ?assertEqual(true, maps:get(served, A)),
        ?assertEqual(<<"c1">>, maps:get(head, A)),
        ?assertEqual(2, maps:get(files_watermarked, A)),
        ?assertEqual(<<"b">>, maps:get(id, B)),
        ?assertEqual(false, maps:get(served, B)),
        ?assertEqual(null, maps:get(head, B)),
        ?assertEqual(2, maps:get(files_watermarked, B))
    after
        meck:unload([corpus_repos_config, rag_store])
    end.

status_tolerates_an_absent_list_test() ->
    ok = meck:new(corpus_repos_config, [no_link]),
    ok = meck:expect(corpus_repos_config, read, fun() -> {error, {config_read_failed, enoent}} end),
    try
        {ok, #{scan := Scan, repos := []}} = ingest_status:status(),
        ?assert(maps:is_key(state, Scan))
    after
        meck:unload(corpus_repos_config)
    end.
