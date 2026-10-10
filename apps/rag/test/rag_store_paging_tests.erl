%%% @doc Paging past barrel's per-call chunk cap (mcl-rag#9).
%%%
%%% `barrel_docdb:find/3' answers at most one chunk per call -- 1,000 rows by
%%% default -- and hands the rest to `has_more'/`continuation' in the meta.
%%% `list_sources_page/3' used to read only that first chunk, so on a corpus
%%% with more than 1,000 sources every page at `offset >= 1000' came back
%%% empty and "how far is ingestion" could not be counted through the public
%%% procedure. This test pages a real store with 1,005 sources across the cap
%%% and asserts the pages.
-module(rag_store_paging_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SOURCES, 1005).
%% The store opens barrel with rag_embedder's provider; paging is not about
%% the model, so the stub stands in (ollama needs a named model).
-define(PROVIDER, {rag_embed_stub, #{dimension => 384}}).

%% Pages that cross barrel's 1,000-row chunk boundary are served whole:
%% within the cap, straddling it, and past it.
paging_across_the_chunk_cap_test_() ->
    {timeout, 180, fun() ->
        with_store(fun() ->
            ok = insert_sources(?SOURCES),
            %% Within the cap.
            {ok, Head} = rag_store:list_sources(0, 10),
            ?assertEqual(10, length(Head)),
            %% Straddling the cap: 10 rows from 995.
            {ok, Straddle} = rag_store:list_sources(995, 10),
            ?assertEqual(10, length(Straddle)),
            ?assertEqual(10, length(unique_ids(Straddle))),
            %% Past the cap: 1005 sources, offset 1000 has exactly 5 left.
            {ok, Tail} = rag_store:list_sources(1000, 10),
            ?assertEqual(5, length(Tail)),
            %% And a page wholly past the end is an empty page, not a crash.
            {ok, Past} = rag_store:list_sources(2000, 10),
            ?assertEqual([], Past),
            %% Head and tail are disjoint pages of the same store.
            HeadIds = unique_ids(Head),
            ?assertEqual([], [Id || Id <- unique_ids(Tail), lists:member(Id, HeadIds)])
        end)
    end}.

%%------------------------------------------------------------------------------
%% helpers
%%------------------------------------------------------------------------------

%% The store opens as part of the `rag' application (rag_sup hosts it, and
%% the open needs the barrel application up): start it the way the node
%% does, wait for the open, and stop it the same way. mcl_rag itself stays
%% down: its mesh surface needs realm config these tests do not carry.
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

insert_sources(N) ->
    lists:foreach(
      fun(I) ->
          Id = list_to_binary(io_lib:format("page-src-~4..0B", [I])),
          ok = rag_store:upsert_source(#{document_id => Id,
                                         source_path => <<"docs/", Id/binary, ".md">>,
                                         source_type => <<"markdown">>,
                                         raw_bytes => <<"x">>})
      end, lists:seq(1, N)),
    ok.

unique_ids(Rows) ->
    lists:usort([maps:get(document_id, R) || R <- Rows]).

restore_provider(undefined) -> application:unset_env(mcl_rag, embed_provider);
restore_provider({ok, P})   -> application:set_env(mcl_rag, embed_provider, P).

await_open(0) -> {error, still_opening};
await_open(N) ->
    case rag_store:status() of
        open    -> ok;
        opening -> timer:sleep(50), await_open(N - 1)
    end.

%% Unique across runs, not only within one VM (same rationale as the opening
%% tests): a previous run's leftover path must not be reused.
scratch_dir() ->
    filename:join(os:getenv("TMPDIR", "/tmp"),
                  lists:concat(["rag_store_paging_", os:getpid(), "_",
                                erlang:system_time(nanosecond)])).
