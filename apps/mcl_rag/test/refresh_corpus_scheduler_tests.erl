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
