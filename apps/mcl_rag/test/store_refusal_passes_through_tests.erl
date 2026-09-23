%%% @doc A desk passes a store refusal through; it does not crash on it.
%%%
%%% The store refuses every call with {error, store_opening} while it opens
%%% (minutes on the production corpus), and can refuse for other reasons. The
%%% desks matched only {error, not_found}, so any other refusal became a
%%% case_clause, function_clause or badmatch inside the caller: a crashed
%%% handler instead of an answer naming why. Each desk here meets a store that
%%% refuses everything and must hand the refusal back.
-module(store_refusal_passes_through_tests).

-include_lib("eunit/include/eunit.hrl").

-define(REFUSED, {error, store_opening}).

every_desk_passes_the_refusal_through_test_() ->
    {setup, fun refusing_store/0, fun(_) -> meck:unload(rag_store) end,
     [{atom_to_list(Desk), ?_assertEqual(?REFUSED, Desk:Fun(Params))}
      || {Desk, Fun, Params} <- desks()]}.

desks() ->
    Doc = #{<<"document_id">> => <<"doc-1">>},
    [{maybe_prune_chunks,         prune,    Doc#{<<"keep_chunk_ids">> => []}},
     {maybe_retire_document,      retire,   Doc},
     {maybe_classify_topics,      classify, Doc},
     {maybe_embed_document,       embed,    Doc},
     {maybe_upload_knowledge,     upload,   Doc#{<<"source_path">> => <<"a.md">>,
                                                 <<"raw_bytes">> => <<"# A\n\ntext\n">>}},
     {maybe_schedule_reembed,     schedule, Doc#{<<"corpus_id">> => <<"c">>,
                                                 <<"source_path">> => <<"a.md">>}},
     {maybe_detect_corpus_change, detect,   #{<<"corpus_id">> => <<"c">>,
                                              <<"source_path">> => <<"a.md">>,
                                              <<"diff_hash">> => <<"h">>}}].

%% Read the exports before meck replaces the module.
refusing_store() ->
    Exports = rag_store:module_info(exports),
    ok = meck:new(rag_store, [no_link]),
    [ok = meck:expect(rag_store, F, refuse(A))
     || {F, A} <- Exports,
        not lists:member(F, [module_info, start_link, init, handle_call,
                             handle_cast, handle_info, terminate, status])].

refuse(0) -> fun() -> ?REFUSED end;
refuse(1) -> fun(_) -> ?REFUSED end;
refuse(2) -> fun(_, _) -> ?REFUSED end;
refuse(3) -> fun(_, _, _) -> ?REFUSED end;
refuse(4) -> fun(_, _, _, _) -> ?REFUSED end.
