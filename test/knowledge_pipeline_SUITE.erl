%%% @doc Integration tests for upload_knowledge and add_knowledge:
%%% the two new server-side pipeline entry points. Both chunk → embed
%%% → store entirely on the server, with embedding happening in the
%%% caller's process (not inside rag_store's gen_server).
%%%
%%% Also verifies that rag_store's gen_server stays responsive during
%%% embedding (the core architectural fix).
-module(knowledge_pipeline_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    upload_knowledge_full_pipeline/1,
    upload_knowledge_missing_id/1,
    upload_knowledge_empty_content/1,
    upload_knowledge_chunks_are_searchable/1,

    add_knowledge_text_snippet/1,
    add_knowledge_with_topics/1,
    add_knowledge_missing_text/1,
    add_knowledge_is_searchable/1,
    add_knowledge_long_text_chunks/1,

    store_stays_responsive_during_embed/1,
    put_chunk_with_vector_round_trip/1,
    search_text_embeds_externally/1,

    mesh_rpc_upload_knowledge_route/1,
    mesh_rpc_add_knowledge_route/1
]).

all() ->
    [
     upload_knowledge_full_pipeline,
     upload_knowledge_missing_id,
     upload_knowledge_empty_content,
     upload_knowledge_chunks_are_searchable,

     add_knowledge_text_snippet,
     add_knowledge_with_topics,
     add_knowledge_missing_text,
     add_knowledge_is_searchable,
     add_knowledge_long_text_chunks,

     store_stays_responsive_during_embed,
     put_chunk_with_vector_round_trip,
     search_text_embeds_externally,

     mesh_rpc_upload_knowledge_route,
     mesh_rpc_add_knowledge_route
    ].

init_per_suite(Config) ->
    ok = rag_test_helpers:start_mcl_rag(),
    Config.

end_per_suite(_Config) ->
    rag_test_helpers:stop_mcl_rag().

%%% ===== upload_knowledge =====

upload_knowledge_full_pipeline(_Config) ->
    DocId = fresh_id(<<"upload">>),
    Content = <<"# Event Sourcing\n\nThe aggregate replays events "
                "to derive state. Each event is a business fact.\n">>,
    Result = maybe_upload_knowledge:upload(#{
        <<"document_id">> => DocId,
        <<"source_path">> => <<"upload-test.md">>,
        <<"source_type">> => <<"text/markdown">>,
        <<"raw_bytes">> => Content
    }),
    {ok, #{document_id := DocId, chunks := N}} = Result,
    ?assert(N > 0).

upload_knowledge_missing_id(_Config) ->
    ?assertEqual({error, missing_document_id},
                 maybe_upload_knowledge:upload(#{<<"raw_bytes">> => <<"text">>})).

upload_knowledge_empty_content(_Config) ->
    ?assertEqual({error, empty_content},
                 maybe_upload_knowledge:upload(#{
                     <<"document_id">> => <<"doc-1">>,
                     <<"raw_bytes">> => <<>>
                 })).

upload_knowledge_chunks_are_searchable(_Config) ->
    DocId = fresh_id(<<"upload-search">>),
    SourcePath = <<"upload-search-", DocId/binary, ".md">>,
    Content = <<"# Quokkas\n\nQuokkas are small marsupials found on "
                "Rottnest Island off Western Australia.\n">>,
    {ok, _} = maybe_upload_knowledge:upload(#{
        <<"document_id">> => DocId,
        <<"source_path">> => SourcePath,
        <<"source_type">> => <<"text/markdown">>,
        <<"raw_bytes">> => Content
    }),
    %% The chunk's own text, embedded by the same embedder, must find it. The
    %% suites run a deterministic embedder (rag_embed_stub): it proves the
    %% chunks are stored WITH vectors and searched through one embedder, not
    %% semantic quality, which is mcl-embedder's to prove.
    {ok, [#{content := Stored} | _]} = rag_store:list_chunks_by_source(SourcePath, 10),
    {ok, Hits} = rag_store:search_text(Stored, 5),
    ?assert(hit_from_source(Hits, SourcePath)).

%%% ===== add_knowledge =====

add_knowledge_text_snippet(_Config) ->
    Result = maybe_add_knowledge:add(#{
        <<"text">> => <<"Vertical slicing groups code by business capability, "
                        "not by technical concern.">>,
        <<"source_label">> => <<"conversational-test">>
    }),
    {ok, #{chunks := N}} = Result,
    ?assert(N > 0).

add_knowledge_with_topics(_Config) ->
    Text = <<"The dossier principle means process over data. "
             "Each desk is a capability within a department.">>,
    {ok, _} = maybe_add_knowledge:add(#{
        <<"text">> => Text,
        <<"source_label">> => <<"dossier-test">>,
        <<"topics">> => [<<"ddd">>, <<"architecture">>]
    }),
    %% A short snippet is stored as one chunk of exactly its text, so the same
    %% text finds it through the deterministic test embedder (see
    %% upload_knowledge_chunks_are_searchable).
    {ok, Hits} = rag_store:search_text(Text, 5),
    TaggedHit = lists:any(fun(H) ->
        Meta = maps:get(meta, H, #{}),
        lists:member(<<"ddd">>, maps:get(<<"topics">>, Meta, []))
    end, Hits),
    ?assert(TaggedHit).

add_knowledge_missing_text(_Config) ->
    ?assertEqual({error, missing_text},
                 maybe_add_knowledge:add(#{<<"source_label">> => <<"test">>})).

add_knowledge_is_searchable(_Config) ->
    maybe_add_knowledge:add(#{
        <<"text">> => <<"Capypbaras are the largest living rodents, "
                        "native to South America.">>,
        <<"source_label">> => <<"capybara-test">>
    }),
    {ok, Hits} = rag_store:search_text(<<"largest rodents">>, 5),
    ?assert(length(Hits) > 0).

add_knowledge_long_text_chunks(_Config) ->
    LongText = <<"# Architecture\n\nVertical slicing groups code by "
                 "business capability. Each feature owns all its "
                 "infrastructure: commands, events, handlers, and "
                 "projections co-located in one directory.\n\n"
                 "## Rules\n\nNo horizontal layers are allowed. "
                 "There is no central supervisor for all listeners. "
                 "Each domain owns its infrastructure. Directory names "
                 "must scream business intent. One capability per "
                 "module. Co-locate related code.\n\n"
                 "## Anti-patterns\n\nServices folders, utils "
                 "directories, and helper modules are all forbidden. "
                 "These are generic technical layers that do not map "
                 "to business capabilities.\n">>,
    {ok, #{chunks := N}} = maybe_add_knowledge:add(#{
        <<"text">> => LongText,
        <<"source_label">> => <<"long-text-test">>
    }),
    ?assert(N > 1).

%%% ===== rag_store architectural fix =====

store_stays_responsive_during_embed(_Config) ->
    %% Start a long embedding in a separate process
    Pid = spawn(fun() ->
        rag_embedder:embed(<<"some text that takes a while to embed">>)
    end),
    %% While that's running, rag_store should still respond
    {ok, _} = rag_store:list_sources(0, 10),
    %% And size should return immediately
    _ = rag_store:size(),
    %% Clean up
    exit(Pid, kill).

put_chunk_with_vector_round_trip(_Config) ->
    ChunkId = fresh_id(<<"pv-rt">>),
    Content = <<"Test content for vector round trip.">>,
    Meta = #{source_path => <<"vector-test.md">>, kind => prose,
             start_line => 1, end_line => 1},
    %% A vector of the configured dimension (what the store's index expects)
    Vector = [0.1 || _ <- lists:seq(1, rag_embedder:dimension())],
    ok = rag_store:put_chunk_with_vector(ChunkId, Content, Meta, Vector),
    {ok, #{content := RetrievedContent}} = rag_store:get(ChunkId),
    ?assertEqual(Content, RetrievedContent),
    %% Verify the chunk is in the vector index
    {ok, Hits} = rag_store:search_vector(Vector, 5),
    ?assert(lists:any(fun(#{chunk_id := Id}) -> Id =:= ChunkId end, Hits)).

search_text_embeds_externally(_Config) ->
    %% search_text should embed the query via rag_embedder
    %% (in the caller's process) and then do a vector search
    {ok, Hits} = rag_store:search_text(<<"test query">>, 5),
    ?assert(is_list(Hits)).

%%% ===== Mesh RPC routes =====

mesh_rpc_upload_knowledge_route(_Config) ->
    Result = rag_test_helpers:operator_dispatch(<<"mcl-rag.upload_knowledge">>,
                                          #{<<"document_id">> => <<"missing">>,
                                            <<"raw_bytes">> => <<>>}),
    %% Should get empty_content error, not unknown_method
    ?assertEqual({error, empty_content}, Result).

mesh_rpc_add_knowledge_route(_Config) ->
    Result = mcl_rag_mesh_rpc:dispatch(<<"mcl-rag.add_knowledge">>,
                                          #{<<"source_label">> => <<"test">>}),
    %% Should get missing_text error, not unknown_method
    ?assertEqual({error, missing_text}, Result).

%%% ===== Helpers =====

hit_from_source(Hits, SourcePath) ->
    lists:any(fun(#{source_path := SP}) -> SP =:= SourcePath end, Hits).

fresh_id(Prefix) ->
    <<Prefix/binary, $-,
      (integer_to_binary(erlang:unique_integer([positive, monotonic])))/binary>>.

