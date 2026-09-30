%% @doc The operator signs its corpus: describe_corpus carries a signed object
%% (macula_signed_object, with the key) over the corpus_hash, under the label
%% the contract names, and the node id of that key as signed_by. A caller
%% verifies the object with the label, checks the signed hash against the one
%% described, and checks that signed_by is the node it called. A node with no
%% identity key describes an unsigned corpus, and says nothing about a
%% signature at all.
-module(corpus_signature_tests).

-include_lib("eunit/include/eunit.hrl").

-define(LABEL, <<"macula-rag corpus v1">>).
-define(HASH_FIELD, {text, <<"corpus_hash">>}).

signed_corpus_test_() ->
    {setup, fun key/0, fun(Key) ->
        [{"the signature verifies under the contract's label, over the described hash",
          fun() -> the_signature_covers_the_described_hash(Key) end},
         {"signed_by is the node id of the key that signed",
          fun() -> signed_by_is_the_signing_node(Key) end},
         {"the label separates it from every other signed object",
          fun() -> another_label_does_not_verify(Key) end},
         {"on the wire the signature stays bytes, the rest is text",
          fun() -> the_signature_travels_as_bytes(Key) end}]
     end}.

%% The fleet's profile (config/sys.config.src). Its key is made once, in setup:
%% hybrid keygen outruns eunit's per-test timeout on a loaded runner.
the_fleet_profile_signs_and_verifies_test_() ->
    {setup, fun() -> {ok, K} = macula_node_keys:generate(identity, pq_hybrid), K end,
     fun(Key) ->
         {timeout, 60, fun() ->
             with_identity({ok, Key}, fun() ->
                 {ok, #{corpus_hash := Hash, signature := Signature}} = describe_corpus:describe(),
                 {ok, Object} = macula_signed_object:decode(Signature),
                 {ok, #{key := Carried, fields := Fields}} =
                     macula_signed_object:verify(?LABEL, Object, pq_hybrid),
                 ?assertEqual({text, Hash}, maps:get(?HASH_FIELD, Fields)),
                 ?assertEqual(macula_node_keys:node_id(Key), {ok, macula_node_keys:node_id(Carried, pq_hybrid)})
             end)
         end}
     end}.

an_unsigned_corpus_says_nothing_about_a_signature_test() ->
    with_identity({error, no_identity_key}, fun() ->
        {ok, D} = describe_corpus:describe(),
        ?assertNot(maps:is_key(signature, D)),
        ?assertNot(maps:is_key(signed_by, D))
    end).

the_signature_covers_the_described_hash(Key) ->
    with_identity({ok, Key}, fun() ->
        {ok, #{corpus_hash := Hash, signature := Signature}} = describe_corpus:describe(),
        {ok, Object} = macula_signed_object:decode(Signature),
        {ok, #{fields := Fields}} = macula_signed_object:verify(?LABEL, Object, pq_pure),
        ?assertEqual({text, Hash}, maps:get(?HASH_FIELD, Fields))
    end).

signed_by_is_the_signing_node(Key) ->
    with_identity({ok, Key}, fun() ->
        {ok, #{signature := Signature, signed_by := SignedBy}} = describe_corpus:describe(),
        {ok, #{key := Carried}} = macula_signed_object:decode(Signature),
        {ok, NodeId} = macula_node_keys:node_id(Key),
        ?assertEqual(binary:encode_hex(NodeId, lowercase), SignedBy),
        ?assertEqual(NodeId, macula_node_keys:node_id(Carried, pq_pure))
    end).

another_label_does_not_verify(Key) ->
    with_identity({ok, Key}, fun() ->
        {ok, #{signature := Signature}} = describe_corpus:describe(),
        {ok, Object} = macula_signed_object:decode(Signature),
        ?assertEqual({error, signature_invalid},
                     macula_signed_object:verify(<<"macula-rag corpus v2">>, Object, pq_pure))
    end).

the_signature_travels_as_bytes(Key) ->
    with_identity({ok, Key}, fun() ->
        {ok, #{signature := Signature, signed_by := {text, _}, corpus_hash := {text, _},
               model := {text, _}}} = mcl_rag_mesh_rpc:handle_describe_corpus(#{}),
        ?assert(is_binary(Signature))
    end).

%%% Internals

key() ->
    {ok, Key} = macula_node_keys:generate(identity, pq_pure),
    Key.

with_identity(Identity, Test) ->
    Was = [{K, application:get_env(mcl_rag, K)} || K <- [corpus_repos_config, embed_model, embed_dim]],
    application:set_env(mcl_rag, corpus_repos_config, "/nonexistent/corpus-repos.json"),
    application:set_env(mcl_rag, embed_model, <<"macula/multilingual-e5-small:f16">>),
    application:set_env(mcl_rag, embed_dim, 384),
    ok = meck:new(mcl_om, [no_link, passthrough]),
    ok = meck:expect(mcl_om, identity_key, fun() -> Identity end),
    try Test()
    after
        meck:unload(mcl_om),
        [restore(K, V) || {K, V} <- Was]
    end.

restore(K, undefined) -> application:unset_env(mcl_rag, K);
restore(K, {ok, V})   -> application:set_env(mcl_rag, K, V).
