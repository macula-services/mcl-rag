%%% @doc Who may delete or rewrite the shared memory.
%%%
%%% Queries and add_knowledge are open to any caller the station admits. The
%%% procedures that delete or rewrite the store are served only to operator
%%% node ids from config (MCL_RAG_OPERATORS), attributed by the caller identity
%%% macula verified, and refused otherwise with {error, not_an_operator}.
%%% The desks are mocked, so each case sees exactly what gets through.
-module(rag_operators_tests).

-include_lib("eunit/include/eunit.hrl").

-define(OP, binary:copy(<<16#0A>>, 32)).
-define(STRANGER, binary:copy(<<16#5B>>, 32)).

-define(OPERATOR_ONLY,
        [classify_topics, detect_corpus_change, embed_document, ingest_document,
         prune_chunks, retire_document, schedule_reembed, upload_knowledge]).

%%------------------------------------------------------------------------------
%% Which procedures
%%------------------------------------------------------------------------------

%% Every procedure that deletes or rewrites the store, and nothing else.
the_operator_only_procedures_are_exactly_these_test() ->
    ?assertEqual(?OPERATOR_ONLY, lists:sort(rag_operators:operator_only())).

%%------------------------------------------------------------------------------
%% The gate, through the mesh handlers
%%------------------------------------------------------------------------------

a_stranger_is_refused_a_destructive_procedure_test() ->
    with_desks(fun() ->
        ?assertEqual({error, not_an_operator},
                     mcl_rag_mesh_rpc:handle_prune_chunks(#{caller => ?STRANGER, document_id => <<"d">>})),
        ?assertEqual(0, meck:num_calls(maybe_prune_chunks, prune, '_'))
    end).

every_operator_only_procedure_refuses_a_stranger_test() ->
    with_desks(fun() ->
        [?assertEqual({P, {error, not_an_operator}},
                      {P, mcl_rag_mesh_rpc:(handler(P))(#{caller => ?STRANGER})})
         || P <- ?OPERATOR_ONLY]
    end).

an_operator_is_served_test() ->
    with_desks(fun() ->
        ?assertMatch({ok, _}, mcl_rag_mesh_rpc:handle_prune_chunks(#{caller => ?OP, document_id => <<"d">>})),
        ?assertEqual(1, meck:num_calls(maybe_prune_chunks, prune, '_'))
    end).

%% No verified caller is no operator.
a_call_with_no_caller_is_refused_test() ->
    with_desks(fun() ->
        ?assertEqual({error, not_an_operator},
                     mcl_rag_mesh_rpc:handle_retire_document(#{document_id => <<"d">>}))
    end).

%% macula overwrites the ATOM key `caller' with the wire-authenticated
%% identity. A caller-supplied binary or text key is not that, and must not
%% be believed even when it names an operator.
a_caller_named_by_the_payload_is_not_believed_test() ->
    with_desks(fun() ->
        Hex = binary:encode_hex(?OP),
        [?assertEqual({error, not_an_operator},
                      mcl_rag_mesh_rpc:handle_retire_document(#{Key => V, document_id => <<"d">>}))
         || {Key, V} <- [{<<"caller">>, ?OP}, {{text, <<"caller">>}, ?OP},
                         {<<"caller">>, Hex}]],
        ?assertEqual(0, meck:num_calls(maybe_retire_document, retire, '_'))
    end).

%% Queries and add_knowledge stay open to anyone the station admitted.
open_procedures_serve_a_stranger_test() ->
    with_desks(fun() ->
        ?assertMatch({ok, _}, mcl_rag_mesh_rpc:handle_add_knowledge(#{caller => ?STRANGER})),
        ?assertMatch({ok, _}, mcl_rag_mesh_rpc:handle_answer_query(#{caller => ?STRANGER}))
    end).

%%------------------------------------------------------------------------------
%% The operator list
%%------------------------------------------------------------------------------

operators_parse_in_any_case_and_separator_test() ->
    Text = <<(string:lowercase(binary:encode_hex(?OP)))/binary, " , ", (binary:encode_hex(?STRANGER))/binary>>,
    ?assertEqual({ok, lists:sort([binary:encode_hex(?OP), binary:encode_hex(?STRANGER)])},
                 rag_operators:parse(Text)).

%% No operators configured is a valid setting: the destructive procedures are
%% then refused to everyone, which is the safe side.
an_empty_list_means_nobody_test() ->
    ?assertEqual({ok, []}, rag_operators:parse("")),
    ?assertEqual({ok, []}, rag_operators:parse(undefined)).

a_malformed_entry_is_refused_test() ->
    ?assertMatch({error, {not_64_hex, _}}, rag_operators:parse("abc")).

%%------------------------------------------------------------------------------
%% helpers
%%------------------------------------------------------------------------------

with_desks(Test) ->
    ok = application:set_env(mcl_rag, operators, binary:encode_hex(?OP)),
    Desks = [{maybe_ingest_document, ingest}, {maybe_embed_document, embed},
             {maybe_upload_knowledge, upload}, {maybe_add_knowledge, add},
             {maybe_classify_topics, classify}, {maybe_prune_chunks, prune},
             {maybe_retire_document, retire}, {maybe_answer_query, retrieve},
             {maybe_detect_corpus_change, detect}, {maybe_schedule_reembed, schedule}],
    [ok = meck:new(M, [non_strict, no_link]) || {M, _} <- Desks],
    [ok = meck:expect(M, F, fun(_) -> {ok, #{}} end) || {M, F} <- Desks],
    try Test()
    after
        meck:unload(),
        application:unset_env(mcl_rag, operators)
    end.

handler(P) -> binary_to_atom(<<"handle_", (atom_to_binary(P))/binary>>).
