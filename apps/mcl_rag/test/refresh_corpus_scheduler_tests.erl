%% @doc One bad file must cost one file, not the scan (issue #3).
%% The refresh loop handles {error, _} returns; an exception used to kill the
%% gen_server and abort the tick, leaving every later file unrefreshed.
-module(refresh_corpus_scheduler_tests).

-include_lib("eunit/include/eunit.hrl").

attempt_passes_a_value_through_test() ->
    ?assertEqual({ok, 42}, refresh_corpus_scheduler:attempt(fun() -> 42 end)).

attempt_captures_an_exception_test() ->
    Result = refresh_corpus_scheduler:attempt(fun() -> binary:last(<<>>) end),
    ?assertMatch({crash, error, badarg, _}, Result).

attempt_captures_an_exit_test() ->
    Result = refresh_corpus_scheduler:attempt(fun() -> exit(boom) end),
    ?assertMatch({crash, exit, boom, _}, Result).

relative_path_keeps_latin1_paths_test() ->
    ?assertEqual(<<"doc.md">>,
                 refresh_corpus_scheduler:relative_path("/root", "/root/doc.md")).

%% Corpus filenames are not all Latin-1: rt-thread's docs include CJK names,
%% and list_to_binary/1 is a badarg above codepoint 255 (issue #7).
relative_path_keeps_unicode_paths_test() ->
    ?assertEqual(<<"目录/文档.md"/utf8>>,
                 refresh_corpus_scheduler:relative_path("/root", "/root/目录/文档.md")).

sanitise_utf8_keeps_valid_text_test() ->
    Text = <<"ok 目录/文档.md"/utf8>>,
    ?assertEqual(Text, refresh_corpus_scheduler:sanitise_utf8(Text)).

%% A GBK/Latin-1 README must ingest with replacement characters instead of
%% crashing the JSON encoder on the way to the embedder (issue #10).
sanitise_utf8_replaces_an_invalid_byte_test() ->
    ?assertEqual(<<"a", 16#FFFD/utf8, "b">>,
                 refresh_corpus_scheduler:sanitise_utf8(<<"a", 174, "b">>)).

sanitise_utf8_replaces_a_truncated_sequence_test() ->
    ?assertEqual(<<"fine", 16#FFFD/utf8, 16#FFFD/utf8>>,
                 refresh_corpus_scheduler:sanitise_utf8(<<"fine", 16#E4, 16#B8>>)).

%% mcl-rag#27: a repo the boot tick reaches while the store still opens is
%% reported, not passed over in silence, and the next tick comes in a minute
%% rather than after the full 2-hour interval.
a_repo_met_while_the_store_opens_is_reported_test() ->
    ok = meck:new(rag_store, [no_link]),
    ok = meck:expect(rag_store, get_served, fun(_) -> {error, store_opening} end),
    try
        ?assertEqual(store_opening,
                     refresh_corpus_scheduler:refresh_repo(#{id => <<"r">>, path => <<"/nonexistent">>},
                                                           binary:copy(<<"1">>, 40)))
    after
        meck:unload(rag_store)
    end.

the_next_tick_is_soon_after_an_opening_store_test() ->
    ?assertEqual(60000, refresh_corpus_scheduler:next_tick([ok, store_opening, ok])),
    ?assertEqual(7200000, refresh_corpus_scheduler:next_tick([ok, ok])),
    ?assertEqual(7200000, refresh_corpus_scheduler:next_tick([])).
