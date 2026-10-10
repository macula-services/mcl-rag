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

%%==============================================================================
%% Live scan progress (mcl-rag#8)
%%==============================================================================

%% progress_start/0 resets the counters and marks the scan running, so a
%% reader can tell a running scan apart from its idle aftermath.
progress_reports_a_running_scan_test() ->
    ok = refresh_corpus_scheduler:progress_start(),
    P = refresh_corpus_scheduler:progress(),
    ?assertEqual(scanning, maps:get(state, P)),
    ?assert(is_integer(maps:get(started_ms, P))),
    ?assertEqual(undefined, maps:get(finished_ms, P)),
    ?assertEqual(0, maps:get(files_seen, P)),
    ?assertEqual(0, maps:get(files_total, P)),
    ?assertEqual(0, maps:get(chunks_written, P)),
    ?assertEqual(0, maps:get(repos_done, P)).

%% A refresh feeds the counters: the file seen and changed, embedded with its
%% chunks counted, and the last-ingest timestamp set.
progress_counts_a_refresh_test() ->
    ok = refresh_corpus_scheduler:progress_start(),
    Root = progress_tmp_root(),
    _ = progress_write_doc(Root, "doc.md", <<"# Hi\n\nSome text.\n">>),
    Head = binary:copy(<<"a">>, 40),
    ok = meck:new([rag_store, maybe_detect_corpus_change, maybe_schedule_reembed, maybe_embed_document], [no_link]),
    ok = meck:expect(rag_store, get_served, fun(_) -> {error, not_found} end),
    ok = meck:expect(rag_store, watermarked_paths, fun(_) -> {ok, []} end),
    ok = meck:expect(rag_store, forget_chunks_of_source, fun(_) -> {ok, 0} end),
    ok = meck:expect(rag_store, upsert_source, fun(_) -> ok end),
    ok = meck:expect(rag_store, forget_chunks_of_repo_except, fun(_, _) -> {ok, 0} end),
    ok = meck:expect(rag_store, put_served, fun(_, _, _) -> ok end),
    ok = meck:expect(maybe_detect_corpus_change, detect, fun(_) -> {ok, #{changed => 1}} end),
    ok = meck:expect(maybe_schedule_reembed, schedule, fun(_) -> ok end),
    ok = meck:expect(maybe_embed_document, embed,
                     fun(_) -> {ok, #{document_id => <<"repo/doc.md">>, chunks => 3}} end),
    try
        ?assertEqual(ok, refresh_corpus_scheduler:refresh_repo(#{id => <<"repo">>, path => Root}, Head)),
        P = refresh_corpus_scheduler:progress(),
        ?assertEqual(1, maps:get(files_seen, P)),
        ?assertEqual(1, maps:get(files_total, P)),
        ?assertEqual(1, maps:get(files_changed, P)),
        ?assertEqual(1, maps:get(files_embedded, P)),
        ?assertEqual(3, maps:get(chunks_written, P)),
        ?assertEqual(0, maps:get(files_failed, P)),
        ?assert(is_integer(maps:get(last_embedded_ms, P))),
        %% current_repo is set by follow_repo (the NIF boundary); the per-file
        %% path is set by the scan itself.
        ?assertEqual(<<"doc.md">>, maps:get(current_path, P))
    after
        meck:unload([rag_store, maybe_detect_corpus_change, maybe_schedule_reembed, maybe_embed_document]),
        _ = file:del_dir_r(Root)
    end.

%% A file that fails is counted, not hidden.
progress_counts_a_failure_test() ->
    ok = refresh_corpus_scheduler:progress_start(),
    Root = progress_tmp_root(),
    _ = progress_write_doc(Root, "bad.md", <<"# Bad\n">>),
    Head = binary:copy(<<"b">>, 40),
    ok = meck:new([rag_store, maybe_detect_corpus_change], [no_link]),
    ok = meck:expect(rag_store, get_served, fun(_) -> {error, not_found} end),
    ok = meck:expect(rag_store, watermarked_paths, fun(_) -> {ok, []} end),
    ok = meck:expect(rag_store, forget_chunks_of_repo_except, fun(_, _) -> {ok, 0} end),
    ok = meck:expect(rag_store, put_served, fun(_, _, _) -> ok end),
    ok = meck:expect(maybe_detect_corpus_change, detect, fun(_) -> {error, refused} end),
    try
        ?assertEqual(ok, refresh_corpus_scheduler:refresh_repo(#{id => <<"repo">>, path => Root}, Head)),
        P = refresh_corpus_scheduler:progress(),
        ?assertEqual(1, maps:get(files_seen, P)),
        ?assertEqual(1, maps:get(files_failed, P)),
        ?assertEqual(0, maps:get(files_changed, P)),
        ?assertEqual(0, maps:get(files_embedded, P))
    after
        meck:unload([rag_store, maybe_detect_corpus_change]),
        _ = file:del_dir_r(Root)
    end.

progress_tmp_root() ->
    Dir = filename:join(["/tmp", "mcl-rag-progress-" ++ integer_to_list(erlang:unique_integer([positive]))]),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    unicode:characters_to_binary(Dir).

progress_write_doc(Root, Name, Content) ->
    Path = filename:join(binary_to_list(Root), Name),
    ok = file:write_file(Path, Content),
    Path.
