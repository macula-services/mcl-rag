%%% @doc Regression coverage for the atom/binary-key mesh payload
%%% hazard documented in mcl_om_wire's own moduledoc: macula's frame
%%% decoder atomizes an inbound payload's keys (binary_to_existing_atom),
%%% so any `from_map/1'/`handle/1' entry point that hard-matched a
%%% binary key silently never matched a real mesh caller's payload,
%%% falling through to a misleading generic error instead of the real
%%% one. Found live 2026-09-01 via `mcl-rag.get_document_verbatim'
%%% and `mcl-rag.get_source_by_id'/`get_chunk_by_id' returning
%%% `unknown_method' at the route/2 dispatch level, and
%%% `detect_corpus_change'/`schedule_reembed' silently returning
%%% `missing_aggregate_id' even when a real corpus_id was supplied.
%%%
%%% Most cases here construct their payload with ATOM keys -- exactly
%%% the shape macula's decoder actually produces -- proving the fix
%%% accepts it, not just that it still accepts the binary-keyed shape
%%% these modules already had coverage for via their own binary-key
%%% call sites elsewhere. A few (marked below) also wrap string VALUES
%%% in `{text, Bin}' -- the CBOR text-string representation
%%% `mcl_om_wire:field/2,3' (>= 0.20.0) unwraps -- since the key
%%% shape alone (fixed first, in mcl_om 0.19.0) turned out not to be
%%% the whole story: a live diagnostic on 2026-09-01 found the real
%%% wire payload was `#{source_path => {text, <<"...">>}}', not
%%% `#{source_path => <<"...">>}' as every test here originally assumed.
%%%
%%% Deliberately EUnit, not a Common Test suite: every function tested
%%% here is a pure map-in/result-out transform with no rag_store or
%%% mesh dependency, so a live application isn't needed to prove the
%%% fix. `list_chunks_by_source'/`search_chunks_semantic'/
%%% `list_sources_page' also needed this fix but call into rag_store,
%%% so their coverage is a live mesh_call verification post-deploy
%%% instead (see PLAN_VERBATIM_RETRIEVAL_AND_FRESHNESS.md).
-module(wire_field_tolerance_tests).

-include_lib("eunit/include/eunit.hrl").

ingest_document_from_map_accepts_atom_keys_test() ->
    {ok, Cmd} = ingest_document_v1:from_map(#{document_id => <<"doc-1">>,
                                              source_path => <<"a.md">>}),
    ?assertEqual(<<"doc-1">>, ingest_document_v1:get_document_id(Cmd)),
    ?assertEqual(<<"a.md">>, ingest_document_v1:get_source_path(Cmd)).

ingest_document_from_map_still_accepts_binary_keys_test() ->
    {ok, Cmd} = ingest_document_v1:from_map(#{<<"document_id">> => <<"doc-1">>}),
    ?assertEqual(<<"doc-1">>, ingest_document_v1:get_document_id(Cmd)).

ingest_document_from_map_missing_id_is_an_error_test() ->
    ?assertEqual({error, missing_document_id}, ingest_document_v1:from_map(#{})).

add_knowledge_from_map_accepts_atom_keys_test() ->
    {ok, Cmd} = add_knowledge_v1:from_map(#{text => <<"hello">>, topics => [<<"a">>]}),
    ?assertEqual(<<"hello">>, add_knowledge_v1:get_text(Cmd)),
    ?assertEqual([<<"a">>], add_knowledge_v1:get_topics(Cmd)).

%% The real shape a genuine mesh call produces after
%% macula_station_link:handle_inbound_call/2's own with_caller/2 merge:
%% an atom `caller' key holding the raw wire-authenticated pubkey,
%% alongside whatever the depositing agent's own payload supplied.
%% Neither add_knowledge_v1 nor upload_knowledge_v1 reads their own
%% `deposited_by' key from the payload directly -- there is no such
%% wire field, `caller' is the only source, which is the whole point:
%% a caller cannot supply their own attribution.
add_knowledge_from_map_reads_caller_as_deposited_by_test() ->
    Pubkey = crypto:strong_rand_bytes(32),
    {ok, Cmd} = add_knowledge_v1:from_map(#{text => <<"hello">>, caller => Pubkey}),
    ?assertEqual(Pubkey, add_knowledge_v1:get_deposited_by(Cmd)).

add_knowledge_from_map_has_no_deposited_by_without_a_caller_test() ->
    {ok, Cmd} = add_knowledge_v1:from_map(#{text => <<"hello">>}),
    ?assertEqual(undefined, add_knowledge_v1:get_deposited_by(Cmd)).

%% Confirms with_caller/2's own guarantee (macula_station_link.erl) is
%% not undermined at this layer: even if the depositing agent's payload
%% names its OWN field `deposited_by', that is not what
%% add_knowledge_v1 reads -- only the real `caller' key is.
add_knowledge_from_map_ignores_a_caller_supplied_deposited_by_field_test() ->
    Pubkey = crypto:strong_rand_bytes(32),
    {ok, Cmd} = add_knowledge_v1:from_map(#{text => <<"hello">>, caller => Pubkey,
                                            deposited_by => <<"spoofed">>}),
    ?assertEqual(Pubkey, add_knowledge_v1:get_deposited_by(Cmd)).

embed_document_from_map_accepts_atom_keys_test() ->
    {ok, Cmd} = embed_document_v1:from_map(#{document_id => <<"doc-1">>}),
    ?assertEqual(<<"doc-1">>, embed_document_v1:get_document_id(Cmd)).

prune_chunks_from_map_accepts_atom_keys_test() ->
    {ok, Cmd} = prune_chunks_v1:from_map(#{document_id => <<"doc-1">>,
                                           chunk_ids => [<<"c1">>]}),
    ?assertEqual(<<"doc-1">>, prune_chunks_v1:get_document_id(Cmd)),
    ?assertEqual([<<"c1">>], prune_chunks_v1:get_chunk_ids(Cmd)).

upload_knowledge_from_map_accepts_atom_keys_test() ->
    {ok, Cmd} = upload_knowledge_v1:from_map(#{document_id => <<"doc-1">>,
                                               raw_bytes => <<"hi">>}),
    ?assertEqual(<<"doc-1">>, upload_knowledge_v1:get_document_id(Cmd)),
    ?assertEqual(<<"hi">>, upload_knowledge_v1:get_raw_bytes(Cmd)).

%% Same coverage as add_knowledge_v1's own three deposited_by tests
%% above -- see those for the full reasoning.
upload_knowledge_from_map_reads_caller_as_deposited_by_test() ->
    Pubkey = crypto:strong_rand_bytes(32),
    {ok, Cmd} = upload_knowledge_v1:from_map(#{document_id => <<"doc-1">>,
                                               raw_bytes => <<"hi">>, caller => Pubkey}),
    ?assertEqual(Pubkey, upload_knowledge_v1:get_deposited_by(Cmd)).

upload_knowledge_from_map_has_no_deposited_by_without_a_caller_test() ->
    {ok, Cmd} = upload_knowledge_v1:from_map(#{document_id => <<"doc-1">>, raw_bytes => <<"hi">>}),
    ?assertEqual(undefined, upload_knowledge_v1:get_deposited_by(Cmd)).

classify_topics_from_map_accepts_atom_keys_test() ->
    {ok, Cmd} = classify_topics_v1:from_map(#{document_id => <<"doc-1">>, max_topics => 3}),
    ?assertEqual(<<"doc-1">>, classify_topics_v1:get_document_id(Cmd)),
    ?assertEqual(3, classify_topics_v1:get_max_topics(Cmd)).

detect_corpus_change_from_map_accepts_atom_keys_test() ->
    {ok, Cmd} = detect_corpus_change_v1:from_map(#{corpus_id => <<"hecate-corpus">>,
                                                    source_path => <<"a.md">>,
                                                    diff_hash => <<"h1">>}),
    ?assertEqual(<<"hecate-corpus">>, detect_corpus_change_v1:get_corpus_id(Cmd)),
    ?assertEqual(<<"a.md">>, detect_corpus_change_v1:get_source_path(Cmd)),
    ?assertEqual(<<"h1">>, detect_corpus_change_v1:get_diff_hash(Cmd)).

%% The exact live symptom: a real corpus_id, atom-keyed (as macula's
%% decoder actually delivers it), used to come back missing_aggregate_id
%% -- indistinguishable from a genuinely absent corpus_id.
detect_corpus_change_from_map_does_not_silently_lose_a_real_corpus_id_test() ->
    Result = detect_corpus_change_v1:from_map(#{corpus_id => <<"real-id">>}),
    ?assertNotEqual({error, missing_aggregate_id}, Result),
    ?assertMatch({ok, _}, Result).

schedule_reembed_from_map_accepts_atom_keys_test() ->
    {ok, Cmd} = schedule_reembed_v1:from_map(#{corpus_id => <<"hecate-corpus">>,
                                               source_path => <<"a.md">>}),
    ?assertEqual(<<"hecate-corpus">>, schedule_reembed_v1:get_corpus_id(Cmd)),
    ?assertEqual(<<"a.md">>, schedule_reembed_v1:get_source_path(Cmd)).

rerank_results_from_map_accepts_atom_keys_test() ->
    {ok, Cmd} = rerank_results_v1:from_map(#{query_id => <<"q1">>,
                                             query_text => <<"weather">>,
                                             hits => [#{score => 0.9}]}),
    ?assertEqual(<<"q1">>, rerank_results_v1:get_query_id(Cmd)),
    ?assertEqual(<<"weather">>, rerank_results_v1:get_query_text(Cmd)).

classify_topics_mode_accepts_atom_keyed_params_test() ->
    ?assertEqual(per_chunk, maybe_classify_topics:mode(#{mode => <<"per_chunk">>})),
    ?assertEqual(document, maybe_classify_topics:mode(#{})).

%%% The realistic wire shape: atom keys AND {text, Bin}-wrapped string
%%% values, exactly as the 2026-09-01 diagnostic found live. These
%%% exercise mcl_om_wire:field/2,3's own unwrap (>= 0.20.0) through
%%% this repo's actual call sites, not just mcl_om's own test suite.

ingest_document_from_map_accepts_the_real_wire_shape_test() ->
    {ok, Cmd} = ingest_document_v1:from_map(
                  #{document_id => {text, <<"doc-1">>},
                    source_path => {text, <<"a.md">>}}),
    ?assertEqual(<<"doc-1">>, ingest_document_v1:get_document_id(Cmd)),
    ?assertEqual(<<"a.md">>, ingest_document_v1:get_source_path(Cmd)).

detect_corpus_change_from_map_accepts_the_real_wire_shape_test() ->
    Result = detect_corpus_change_v1:from_map(
               #{corpus_id => {text, <<"real-id">>},
                 source_path => {text, <<"a.md">>},
                 diff_hash => {text, <<"h1">>}}),
    ?assertNotEqual({error, missing_aggregate_id}, Result),
    {ok, Cmd} = Result,
    ?assertEqual(<<"real-id">>, detect_corpus_change_v1:get_corpus_id(Cmd)),
    ?assertEqual(<<"a.md">>, detect_corpus_change_v1:get_source_path(Cmd)).

rerank_results_from_map_accepts_the_real_wire_shape_including_topics_list_test() ->
    {ok, Cmd} = rerank_results_v1:from_map(
                  #{query_id => {text, <<"q1">>},
                    query_text => {text, <<"weather">>},
                    hits => [#{content => {text, <<"first">>}, score => 0.9}]}),
    ?assertEqual(<<"q1">>, rerank_results_v1:get_query_id(Cmd)),
    ?assertEqual(<<"weather">>, rerank_results_v1:get_query_text(Cmd)),
    ?assertEqual([#{content => <<"first">>, score => 0.9}],
                 rerank_results_v1:get_hits(Cmd)).

classify_topics_mode_accepts_a_cbor_text_tuple_value_test() ->
    ?assertEqual(per_chunk, maybe_classify_topics:mode(#{mode => {text, <<"per_chunk">>}})).
