%%% @doc Pure coverage for the `deposited_by' tagging step both
%%% `maybe_add_knowledge' and `maybe_upload_knowledge' apply to their
%%% chunks before handing them to `rag_chunk_embedder:embed_and_store/1'
%%% -- no embedder or store needed, same posture as
%%% `wire_field_tolerance_tests.erl''s own moduledoc for exactly this
%%% reason. The end-to-end proof that a real mesh call's `caller' ends
%%% up stored and retrievable is a live verification against a running
%%% instance, not here -- see that module's own doc on why (macula's
%%% caller-merge only happens on the real inbound CALL path,
%%% `dispatch/2' bypasses it entirely).
-module(deposited_by_tests).

-include_lib("eunit/include/eunit.hrl").

-define(PUBKEY, <<1:256>>).
%% Computed, not transcribed by hand -- the point is agreement with
%% binary:encode_hex/2 itself, not a hand-copied hex literal that could
%% quietly drift from what the function actually produces.
-define(PUBKEY_HEX, binary:encode_hex(?PUBKEY, lowercase)).

%%% maybe_add_knowledge:with_deposited_by/2

add_knowledge_tags_every_chunk_with_hex_encoded_deposited_by_test() ->
    Chunks = [#{chunk_id => <<"a">>, content => <<"x">>},
              #{chunk_id => <<"b">>, content => <<"y">>}],
    Tagged = maybe_add_knowledge:with_deposited_by(Chunks, ?PUBKEY),
    ?assertEqual([?PUBKEY_HEX, ?PUBKEY_HEX],
                 [maps:get(deposited_by, C) || C <- Tagged]).

add_knowledge_leaves_chunks_untouched_without_a_caller_test() ->
    Chunks = [#{chunk_id => <<"a">>, content => <<"x">>}],
    ?assertEqual(Chunks, maybe_add_knowledge:with_deposited_by(Chunks, undefined)).

add_knowledge_deposited_by_is_hex_not_raw_bytes_test() ->
    %% A raw 32-byte pubkey would round-trip through barrel's JSON-shaped
    %% storage as unprintable bytes -- confirms the tag is the printable
    %% hex form, not the wire value passed in.
    [Tagged] = maybe_add_knowledge:with_deposited_by([#{chunk_id => <<"a">>, content => <<"x">>}], ?PUBKEY),
    Hex = maps:get(deposited_by, Tagged),
    ?assertEqual(64, byte_size(Hex)),
    ?assert(is_binary(Hex)),
    ?assertNotEqual(?PUBKEY, Hex).

%%% maybe_upload_knowledge:with_deposited_by/2 -- identical contract

upload_knowledge_tags_every_chunk_with_hex_encoded_deposited_by_test() ->
    Chunks = [#{chunk_id => <<"a">>, content => <<"x">>},
              #{chunk_id => <<"b">>, content => <<"y">>}],
    Tagged = maybe_upload_knowledge:with_deposited_by(Chunks, ?PUBKEY),
    ?assertEqual([?PUBKEY_HEX, ?PUBKEY_HEX],
                 [maps:get(deposited_by, C) || C <- Tagged]).

upload_knowledge_leaves_chunks_untouched_without_a_caller_test() ->
    Chunks = [#{chunk_id => <<"a">>, content => <<"x">>}],
    ?assertEqual(Chunks, maybe_upload_knowledge:with_deposited_by(Chunks, undefined)).

%% The exact byte-for-byte agreement between the two modules' hex
%% encoding matters: a chunk from either write path must be
%% attributable by the SAME hex string for the same real caller, not
%% two different encodings of the same pubkey.
both_modules_hex_encode_the_same_pubkey_identically_test() ->
    [FromAdd] = maybe_add_knowledge:with_deposited_by([#{chunk_id => <<"a">>, content => <<"x">>}], ?PUBKEY),
    [FromUpload] = maybe_upload_knowledge:with_deposited_by([#{chunk_id => <<"a">>, content => <<"x">>}], ?PUBKEY),
    ?assertEqual(maps:get(deposited_by, FromAdd), maps:get(deposited_by, FromUpload)).
