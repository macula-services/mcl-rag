%%% @doc Integration tests for the mesh RPC route table
%%% (mcl_rag_mesh_rpc:route/2). Exists because the barrel migration
%%% rewrote every ingest/embed/prune/answer_query handler to a plain
%%% function (ingest/1, embed/1, prune/1, retrieve/1) but the mesh route
%%% table kept calling the OLD evoq-command shape (CmdMod:from_map/1 then
%%% HandlerMod:dispatch/1, a function none of the four still export) —
%%% invisible to embed_corpus_SUITE, which calls the handlers directly and
%%% never went through this route table. A mesh caller (a plugin, a
%%% Spartan mind's rag_search tool) would have gotten `undef' on every one
%%% of these methods. This asserts the mesh path, not just the handlers.
-module(mcl_rag_mesh_rpc_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([ingest_embed_search_answer_prune_over_mesh_rpc/1,
         unknown_method_is_rejected/1]).

all() ->
    [ingest_embed_search_answer_prune_over_mesh_rpc, unknown_method_is_rejected].

init_per_suite(Config) ->
    ok = rag_test_helpers:start_mcl_rag(),
    Config.

end_per_suite(_Config) ->
    rag_test_helpers:stop_mcl_rag().

ingest_embed_search_answer_prune_over_mesh_rpc(_Config) ->
    DocId = fresh_id(),
    SourcePath = <<"capybara-", DocId/binary, ".md">>,
    Content = <<"# The Capybara\n\nCapybaras are the largest living "
                "rodents, native to South America.\n">>,

    %% Every reply through dispatch/2 is the MESH shape: each string in
    %% it is `{text, Bin}'-tagged at the boundary (mcl_rag_mesh_rpc's
    %% own moduledoc says why) -- so a bare-binary match here would be
    %% asserting the HTTP shape against the mesh route.
    {ok, #{document_id := {text, DocId}}} =
        rag_test_helpers:operator_dispatch(<<"mcl-rag.ingest_document">>, #{
            <<"document_id">> => DocId, <<"source_path">> => SourcePath,
            <<"source_type">> => <<"text/markdown">>, <<"raw_bytes">> => Content
        }),

    {ok, #{chunks := N}} =
        rag_test_helpers:operator_dispatch(<<"mcl-rag.embed_document">>,
                                      #{<<"document_id">> => DocId}),
    ?assert(N > 0),

    {ok, Hits} = mcl_rag_mesh_rpc:dispatch(<<"mcl-rag.search_chunks_semantic">>,
                                               #{<<"query_text">> => <<"largest rodent">>,
                                                 <<"top_k">> => 5}),
    ?assert(hit_from_source(Hits, SourcePath)),
    %% ...and a hit's content reaches the wire as tagged, non-empty text.
    ?assertMatch([#{content := {text, <<_, _/binary>>}} | _],
                 [H || #{source_path := SP} = H <- Hits, SP =:= {text, SourcePath}]),

    {ok, #{hits := AnswerHits}} =
        mcl_rag_mesh_rpc:dispatch(<<"mcl-rag.answer_query">>,
                                      #{<<"query_text">> => <<"largest rodent">>, <<"top_k">> => 5}),
    ?assert(hit_from_source(AnswerHits, SourcePath)),

    {ok, _} = rag_test_helpers:operator_dispatch(<<"mcl-rag.prune_chunks">>,
                                            #{<<"document_id">> => DocId}),
    {ok, GoneHits} = mcl_rag_mesh_rpc:dispatch(<<"mcl-rag.search_chunks_semantic">>,
                                                   #{<<"query_text">> => <<"largest rodent">>,
                                                     <<"top_k">> => 5}),
    ?assertNot(hit_from_source(GoneHits, SourcePath)).

unknown_method_is_rejected(_Config) ->
    ?assertEqual({error, {unknown_method, <<"mcl-rag.nonsense">>}},
                 mcl_rag_mesh_rpc:dispatch(<<"mcl-rag.nonsense">>, #{})).

%%% Internals

%% Mesh shape: `source_path' arrives `{text, _}'-tagged (see the test above).
hit_from_source(Hits, SourcePath) ->
    lists:any(fun(#{source_path := SP}) -> SP =:= {text, SourcePath} end, Hits).

fresh_id() ->
    integer_to_binary(erlang:unique_integer([positive, monotonic])).
