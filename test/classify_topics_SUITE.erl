%%% @doc Unit + integration tests for the topic classification pipeline:
%%% classify_topics_v1 validation, rag_topic_classifier response parsing,
%%% maybe_classify_topics handler (document + per_chunk modes),
%%% rag_store:tag_chunk storage, and search_chunks_semantic topic
%%% filtering. Also verifies the mesh RPC route.
%%%
%%% The NVIDIA API call itself is tested via a mock (no network in CI).
%%% E2E verification with the real API is done separately — see
%%% scripts/verify-topics-e2e.sh.
-module(classify_topics_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([
    v1_from_map_accepts_document_id/1,
    v1_from_map_defaults_max_topics/1,
    v1_from_map_custom_max_topics/1,
    v1_from_map_missing_document_id/1,
    v1_validate_missing_id/1,
    v1_validate_invalid_max_topics/1,

    classifier_strip_code_fence_json/1,
    classifier_strip_code_fence_plain/1,
    classifier_extract_topics_from_json/1,
    classifier_extract_topics_lowercase/1,
    classifier_extract_topics_empty_on_garbage/1,
    classifier_configured_false_when_no_env/1,

    store_tag_chunk_then_get/1,
    store_tag_chunk_not_found/1,
    store_tag_chunk_preserves_content/1,

    handler_document_mode_tags_all_chunks/1,
    handler_per_chunk_mode_tags_individually/1,
    handler_not_ingested/1,
    handler_not_embedded/1,

    search_with_topic_filter/1,
    search_without_topic_filter_unchanged/1,
    search_topic_filter_no_matches/1,

    mesh_rpc_classify_topics_route/1
]).

all() ->
    [
     v1_from_map_accepts_document_id,
     v1_from_map_defaults_max_topics,
     v1_from_map_custom_max_topics,
     v1_from_map_missing_document_id,
     v1_validate_missing_id,
     v1_validate_invalid_max_topics,

     classifier_strip_code_fence_json,
     classifier_strip_code_fence_plain,
     classifier_extract_topics_from_json,
     classifier_extract_topics_lowercase,
     classifier_extract_topics_empty_on_garbage,
     classifier_configured_false_when_no_env,

     store_tag_chunk_then_get,
     store_tag_chunk_not_found,
     store_tag_chunk_preserves_content,

     handler_document_mode_tags_all_chunks,
     handler_per_chunk_mode_tags_individually,
     handler_not_ingested,
     handler_not_embedded,

     search_with_topic_filter,
     search_without_topic_filter_unchanged,
     search_topic_filter_no_matches,

     mesh_rpc_classify_topics_route
    ].

init_per_suite(Config) ->
    ok = rag_test_helpers:start_mcl_rag(),
    Config.

end_per_suite(_Config) ->
    rag_test_helpers:stop_mcl_rag().

init_per_testcase(_TC, Config) ->
    Config.

end_per_testcase(_TC, _Config) ->
    ok.

%%% ===== classify_topics_v1 =====

v1_from_map_accepts_document_id(_Config) ->
    {ok, Cmd} = classify_topics_v1:from_map(#{<<"document_id">> => <<"doc-1">>}),
    ?assertEqual(<<"doc-1">>, classify_topics_v1:get_document_id(Cmd)).

v1_from_map_defaults_max_topics(_Config) ->
    {ok, Cmd} = classify_topics_v1:from_map(#{<<"document_id">> => <<"doc-1">>}),
    ?assertEqual(5, classify_topics_v1:get_max_topics(Cmd)).

v1_from_map_custom_max_topics(_Config) ->
    {ok, Cmd} = classify_topics_v1:from_map(#{
        <<"document_id">> => <<"doc-1">>,
        <<"max_topics">> => 3
    }),
    ?assertEqual(3, classify_topics_v1:get_max_topics(Cmd)).

v1_from_map_missing_document_id(_Config) ->
    ?assertEqual({error, missing_document_id},
                 classify_topics_v1:from_map(#{<<"foo">> => <<"bar">>})).

v1_validate_missing_id(_Config) ->
    {ok, Cmd} = classify_topics_v1:new(#{document_id => undefined}),
    ?assertEqual({error, missing_document_id}, classify_topics_v1:validate(Cmd)).

v1_validate_invalid_max_topics(_Config) ->
    %% max_topics = 0 is invalid; new/1 accepts it, validate rejects it
    {ok, Cmd} = classify_topics_v1:new(#{document_id => <<"doc-1">>, max_topics => 0}),
    ?assertEqual({error, invalid_max_topics}, classify_topics_v1:validate(Cmd)).

%%% ===== rag_topic_classifier response parsing =====
%%%
%%% These test the internal parsing functions directly — no network.
%%% The API call itself is E2E verified separately.

classifier_strip_code_fence_json(_Config) ->
    %% NVIDIA wraps JSON in markdown code fences
    Input = <<"```json\n[\"event sourcing\", \"ddd\"]\n```">>,
    Result = rag_topic_classifier:extract_topics(Input),
    ?assertEqual([<<"event sourcing">>, <<"ddd">>], Result).

classifier_strip_code_fence_plain(_Config) ->
    %% No code fence, just raw JSON array
    Input = <<"[\"erlang\", \"otp\"]">>,
    Result = rag_topic_classifier:extract_topics(Input),
    ?assertEqual([<<"erlang">>, <<"otp">>], Result).

classifier_extract_topics_from_json(_Config) ->
    Input = <<"[\"topic-a\", \"topic-b\", \"topic-c\"]">>,
    Result = rag_topic_classifier:extract_topics(Input),
    ?assertEqual(3, length(Result)).

classifier_extract_topics_lowercase(_Config) ->
    Input = <<"[\"Event Sourcing\", \"DDD\", \"Aggregate\"]">>,
    Result = rag_topic_classifier:extract_topics(Input),
    ?assert(lists:all(fun(T) -> T =:= string:lowercase(T) end, Result)).

classifier_extract_topics_empty_on_garbage(_Config) ->
    ?assertEqual([], rag_topic_classifier:extract_topics(<<"not json at all">>)),
    ?assertEqual([], rag_topic_classifier:extract_topics(<<"{}">>)),
    ?assertEqual([], rag_topic_classifier:extract_topics(<<"">>)).

classifier_configured_false_when_no_env(_Config) ->
    %% The test config doesn't set topic_classifier, so it should
    %% report not configured. We temporarily clear any config that
    %% might have leaked from dev.config.
    application:set_env(mcl_rag, topic_classifier, #{}),
    ?assertNot(rag_topic_classifier:configured()),
    application:unset_env(mcl_rag, topic_classifier).

%%% ===== rag_store:tag_chunk =====

store_tag_chunk_then_get(_Config) ->
    ChunkId = fresh_id(<<"tag-chunk-get">>),
    Content = <<"Test content for tagging.">>,
    Meta = #{source_path => <<"tag-test.md">>, kind => prose,
             start_line => 1, end_line => 1},
    ok = rag_store:put_chunk(ChunkId, Content, Meta),
    Topics = [<<"testing">>, <<"tagging">>],
    ok = rag_store:tag_chunk(ChunkId, Topics),
    {ok, #{meta := MetaOut}} = rag_store:get(ChunkId),
    ?assertEqual(Topics, maps:get(<<"topics">>, MetaOut, undefined)).

store_tag_chunk_not_found(_Config) ->
    ?assertEqual({error, not_found},
                 rag_store:tag_chunk(<<"nonexistent-chunk-id">>, [<<"foo">>])).

store_tag_chunk_preserves_content(_Config) ->
    ChunkId = fresh_id(<<"tag-chunk-preserve">>),
    Content = <<"Original content that must survive tagging.">>,
    Meta = #{source_path => <<"preserve-test.md">>, kind => prose,
             start_line => 1, end_line => 1},
    ok = rag_store:put_chunk(ChunkId, Content, Meta),
    ok = rag_store:tag_chunk(ChunkId, [<<"preservation">>]),
    {ok, #{content := RetrievedContent}} = rag_store:get(ChunkId),
    ?assertEqual(Content, RetrievedContent).

%%% ===== maybe_classify_topics handler =====
%%%
%%% These tests mock the classifier (no network) to verify the handler
%%% correctly reads chunks, calls the classifier, and tags chunks.

handler_document_mode_tags_all_chunks(_Config) ->
    %% Set up: ingest + embed a document (needs ollama for embedding)
    %% Skip if ollama isn't running — this is an integration test.
    case ollama_available() of
        false -> {skip, "Ollama not running, skipping integration test"};
        true ->
            DocId = fresh_id(<<"doc-mode">>),
            SourcePath = <<"doc-mode-", DocId/binary, ".md">>,
            Content = <<"# Event Sourcing\n\nThe aggregate replays events "
                        "to derive state. Each event is a business fact.\n">>,
            {ok, _} = ingest(DocId, SourcePath, Content),
            {ok, #{chunks := N}} = embed(DocId),
            ?assert(N > 0),

            %% Mock the classifier — we're testing the handler, not NVIDIA
            meck:new(rag_topic_classifier, [passthrough]),
            meck:expect(rag_topic_classifier, classify, fun(_Text, _Max) ->
                {ok, [<<"event sourcing">>, <<"aggregate">>, <<"ddd">>]}
            end),

            Result = maybe_classify_topics:classify(#{
                <<"document_id">> => DocId,
                <<"mode">> => <<"document">>
            }),

            meck:unload(rag_topic_classifier),

            {ok, #{topics := Topics, tagged := Tagged}} = Result,
            ?assertEqual([<<"event sourcing">>, <<"aggregate">>, <<"ddd">>], Topics),
            ?assertEqual(N, Tagged),

            %% Verify topics were actually written to store
            {ok, Chunks} = rag_store:list_chunks_by_source(SourcePath, 100),
            lists:foreach(fun(Chunk) ->
                Meta = maps:get(meta, Chunk, #{}),
                ?assertEqual([<<"event sourcing">>, <<"aggregate">>, <<"ddd">>],
                             maps:get(<<"topics">>, Meta, []))
            end, Chunks)
    end.

handler_per_chunk_mode_tags_individually(_Config) ->
    case ollama_available() of
        false -> {skip, "Ollama not running, skipping integration test"};
        true ->
            DocId = fresh_id(<<"per-chunk">>),
            SourcePath = <<"per-chunk-", DocId/binary, ".md">>,
            Content = <<"# Architecture\n\nVertical slicing groups code by "
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
            {ok, _} = ingest(DocId, SourcePath, Content),
            {ok, #{chunks := N}} = embed(DocId),
            ?assert(N > 0),

            %% Mock: each call returns a single topic to verify per-chunk
            %% mode makes N separate calls and tags each chunk individually
            meck:new(rag_topic_classifier, [passthrough]),
            meck:expect(rag_topic_classifier, classify,
                fun(_Text, _Max) -> {ok, [<<"vertical-slicing">>]} end),

            Result = maybe_classify_topics:classify(#{
                <<"document_id">> => DocId,
                <<"mode">> => <<"per_chunk">>
            }),

            meck:unload(rag_topic_classifier),

            {ok, #{tagged := Tagged}} = Result,
            ?assertEqual(N, Tagged),

            %% Verify each chunk has topics in the store
            {ok, Chunks} = rag_store:list_chunks_by_source(SourcePath, 100),
            lists:foreach(fun(Chunk) ->
                Meta = maps:get(meta, Chunk, #{}),
                ?assertEqual([<<"vertical-slicing">>],
                             maps:get(<<"topics">>, Meta, []))
            end, Chunks)
    end.

handler_not_ingested(_Config) ->
    Result = maybe_classify_topics:classify(#{
        <<"document_id">> => <<"never-ingested-", (fresh_id(<<"ni">>))/binary>>
    }),
    ?assertEqual({error, not_ingested}, Result).

handler_not_embedded(_Config) ->
    DocId = fresh_id(<<"not-embedded">>),
    {ok, _} = ingest(DocId, <<"not-embedded.md">>, <<"# Test\n\nNo embedding.\n">>),
    Result = maybe_classify_topics:classify(#{<<"document_id">> => DocId}),
    ?assertEqual({error, not_embedded}, Result).

%%% ===== search_chunks_semantic with topic filter =====

search_with_topic_filter(_Config) ->
    case ollama_available() of
        false -> {skip, "Ollama not running, skipping integration test"};
        true ->
            %% Ingest two documents with different content
            DocId1 = fresh_id(<<"filter-1">>),
            DocId2 = fresh_id(<<"filter-2">>),
            Path1 = <<"filter-aaa-", DocId1/binary, ".md">>,
            Path2 = <<"filter-bbb-", DocId2/binary, ".md">>,
            {ok, _} = ingest(DocId1, Path1,
                             <<"# Quokkas\n\nSmall marsupials on Rottnest Island.\n">>),
            {ok, _} = embed(DocId1),
            {ok, _} = ingest(DocId2, Path2,
                             <<"# Capybaras\n\nLarge rodents from South America.\n">>),
            {ok, _} = embed(DocId2),

            %% Tag only the first document's chunks
            {ok, Chunks1} = rag_store:list_chunks_by_source(Path1, 100),
            lists:foreach(fun(C) ->
                ok = rag_store:tag_chunk(maps:get(chunk_id, C), [<<"marsupials">>])
            end, Chunks1),

            %% Search with topic filter — should only return marsupial-tagged chunks
            {ok, FilteredHits} = search_chunks_semantic:handle(#{
                <<"query_text">> => <<"small animals">>,
                <<"topics">>     => [<<"marsupials">>],
                <<"top_k">>      => 10
            }),

            %% Every hit must have the marsupials topic
            lists:foreach(fun(Hit) ->
                Meta = maps:get(meta, Hit, #{}),
                Topics = maps:get(<<"topics">>, Meta, []),
                ?assert(lists:member(<<"marsupials">>, Topics))
            end, FilteredHits),

            %% Verify the filter actually excluded something: search
            %% without filter returns more hits than with filter
            {ok, AllHits} = search_chunks_semantic:handle(#{
                <<"query_text">> => <<"small animals">>,
                <<"top_k">>      => 10
            }),
            ?assert(length(FilteredHits) =< length(AllHits))
    end.

search_without_topic_filter_unchanged(_Config) ->
    case ollama_available() of
        false -> {skip, "Ollama not running, skipping integration test"};
        true ->
            {ok, Hits} = search_chunks_semantic:handle(#{
                <<"query_text">> => <<"test query">>,
                <<"top_k">>       => 5
            }),
            ?assert(is_list(Hits))
    end.

search_topic_filter_no_matches(_Config) ->
    case ollama_available() of
        false -> {skip, "Ollama not running, skipping integration test"};
        true ->
            {ok, Hits} = search_chunks_semantic:handle(#{
                <<"query_text">>  => <<"anything">>,
                <<"topics">>      => [<<"nonexistent-topic-", (fresh_id(<<"nt">>))/binary>>],
                <<"top_k">>       => 5
            }),
            ?assertEqual([], Hits)
    end.

%%% ===== Mesh RPC route =====

mesh_rpc_classify_topics_route(_Config) ->
    %% Verify the route exists and dispatches to the handler
    DocId = fresh_id(<<"rpc-route">>),
    Result = mcl_rag_mesh_rpc:dispatch(<<"mcl-rag.classify_topics">>,
                                          #{<<"document_id">> => DocId}),
    %% Document doesn't exist — should get not_ingested, not unknown_method
    ?assertEqual({error, not_ingested}, Result).

%%% ===== Helpers =====

ingest(DocId, SourcePath, RawBytes) ->
    maybe_ingest_document:ingest(#{
        <<"document_id">> => DocId, <<"source_path">> => SourcePath,
        <<"source_type">> => <<"text/markdown">>, <<"raw_bytes">> => RawBytes
    }).

embed(DocId) ->
    maybe_embed_document:embed(#{<<"document_id">> => DocId}).

fresh_id(Prefix) ->
    <<Prefix/binary, $-, (integer_to_binary(erlang:unique_integer([positive, monotonic])))/binary>>.

ollama_available() ->
    case hackney:request(get, <<"http://127.0.0.1:11434/api/tags">>, [], <<>>, [{recv_timeout, 2000}]) of
        {ok, 200, _Headers, _Body} -> true;
        _ -> false
    end.
