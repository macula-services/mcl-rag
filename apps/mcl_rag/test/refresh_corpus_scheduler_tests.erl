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
