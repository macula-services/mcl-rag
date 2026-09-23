%%% @doc The store opens at start, off its own process, and says so while it
%%% does.
%%%
%%% Opening the production store rebuilds its HNSW index: 227 s for beam03's
%%% 22,316 vectors on a workstation, longer on a Celeron. Opened lazily inside
%%% the gen_server, the first call blocked it for all of that and every caller
%%% queued behind it died on the 60 s call timeout, while size and the list
%%% queries would have answered 0 and [] had the open failed: a retire that
%%% "found no chunks" and reported success. So: the open starts at init in a
%%% linked process, every call during it is refused with
%%% {error, store_opening}, /health is degraded until it lands, and an open
%%% that fails stops the store, loudly.
-module(rag_store_opening_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DB, #{name => <<"rag_chunks">>}).

%% A call during the open is refused at once, not queued behind it.
a_call_during_the_open_is_refused_not_queued_test() ->
    with_held_open(fun(_Opener) ->
        ?assertEqual({error, store_opening}, rag_store:size()),
        ?assertEqual({error, store_opening}, rag_store:list_chunks_by_source(<<"a.md">>, 10)),
        ?assertEqual({error, store_opening}, rag_store:list_sources(0, 10)),
        ?assertEqual({error, store_opening}, rag_store:get(<<"c">>))
    end).

%% The open starts at init, before anyone calls.
the_open_starts_before_any_call_test() ->
    with_held_open(fun(Opener) -> ?assert(is_pid(Opener)) end).

%% When the open lands, the store serves.
the_store_serves_once_open_test() ->
    with_held_open(fun(Opener) ->
        ?assertEqual(opening, rag_store:status()),
        Opener ! release,
        ok = await_open(50),
        ?assertEqual(open, rag_store:status())
    end).

%% The vector store must not be the opener's child: the opener exits after
%% the open, and a store linked to it would go with it.
the_vector_store_is_supervised_by_barrel_test() ->
    with_held_open(fun(Opener) ->
        Opener ! release,
        ok = await_open(50),
        [{_Pid, {barrel, open, [_Name, Opts]}, _} | _] = meck:history(barrel),
        ?assertEqual(true, maps:get(store_supervised, Opts))
    end).

%% An open that fails stops the store; it does not linger answering 0.
a_failed_open_stops_the_store_test() ->
    ?assertEqual({store_open_failed, boom}, stop_reason(scratch_dir(), {error, boom})).

%% A data dir that cannot be made is named, with the path, in the stop reason.
an_unusable_data_dir_is_named_test() ->
    File = scratch_dir(),
    ok = file:write_file(File, <<>>),
    Dir = filename:join(File, "data"),
    try
        ?assertMatch({store_open_failed, {data_dir_unusable, Dir, _}},
                     stop_reason(Dir, {ok, ?DB}))
    after
        file:delete(File)
    end.

%%------------------------------------------------------------------------------
%% helpers
%%------------------------------------------------------------------------------

%% barrel:open/2 blocks until the test sends `release' to the opener.
with_held_open(Test) ->
    Self = self(),
    ok = meck:new(barrel, [non_strict, no_link]),
    ok = meck:expect(barrel, open, fun(_, _) ->
        Self ! {opener, self()},
        receive release -> {ok, ?DB} end
    end),
    Dir = scratch_dir(),
    ok = application:set_env(mcl_rag, data_dir, Dir),
    {ok, Pid} = rag_store:start_link(),
    unlink(Pid),
    try
        Opener = receive {opener, O} -> O after 1000 -> error(open_not_started) end,
        Test(Opener)
    after
        exit(Pid, shutdown),
        wait_down(Pid),
        meck:unload(barrel),
        application:unset_env(mcl_rag, data_dir),
        file:del_dir_r(Dir)
    end.

stop_reason(DataDir, OpenResult) ->
    ok = meck:new(barrel, [non_strict, no_link]),
    ok = meck:expect(barrel, open, fun(_, _) -> OpenResult end),
    ok = application:set_env(mcl_rag, data_dir, DataDir),
    process_flag(trap_exit, true),
    try
        {ok, Pid} = rag_store:start_link(),
        receive {'EXIT', Pid, Reason} -> Reason after 5000 -> still_running end
    after
        process_flag(trap_exit, false),
        meck:unload(barrel),
        application:unset_env(mcl_rag, data_dir),
        file:del_dir_r(DataDir)
    end.

await_open(0) -> {error, still_opening};
await_open(N) ->
    case rag_store:status() of
        open    -> ok;
        opening -> timer:sleep(20), await_open(N - 1)
    end.

wait_down(Pid) ->
    Ref = monitor(process, Pid),
    receive {'DOWN', Ref, process, Pid, _} -> ok after 5000 -> ok end.

%% Unique across runs, not only within one VM: unique_integer restarts with
%% every VM, and a path a previous run left behind (as a file) made these
%% tests fail one run in two.
scratch_dir() ->
    filename:join(os:getenv("TMPDIR", "/tmp"),
                  lists:concat(["rag_store_opening_", os:getpid(), "_",
                                erlang:system_time(nanosecond)])).
