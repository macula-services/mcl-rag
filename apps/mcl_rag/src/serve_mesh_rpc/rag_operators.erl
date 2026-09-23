%% @doc Who may delete or rewrite the shared memory.
%%
%% Queries and add_knowledge are open to any caller the station admits. The
%% procedures that delete or rewrite what is already stored are served only to
%% an OPERATOR: a node id listed in config (`operators', MCL_RAG_OPERATORS),
%% attributed by the caller identity macula verified. Anyone else gets
%% `{error, not_an_operator}'.
%%
%% THE CALLER IS READ FROM THE ATOM KEY `caller' ONLY. macula writes that key
%% with the wire-authenticated identity after decoding the payload, overwriting
%% anything the caller put there. It does not touch a binary or text key named
%% "caller", which a caller can set to anything, so neither is ever read here.
%% (mcl_om_wire:field/2 reads all three forms, which is right for data and
%% wrong for identity.)
%%
%% An empty operator list is valid and means nobody: the destructive
%% procedures are then refused to everyone.
-module(rag_operators).

-export([operator_only/0, authorized/2, parse/1]).

-define(HEX64, "^[0-9A-F]{64}$").
-define(SEPARATORS, [$,, $\s, $\t, $\n, $\r, "\r\n"]).

%% @doc The procedures served only to operators: each deletes, replaces or
%% rewrites what the store already holds.
%%
%%   prune_chunks, retire_document   delete chunks, or a document and its chunks
%%   ingest_document, upload_knowledge  upsert a source by document_id, replacing
%%                                      an existing document
%%   embed_document                  re-chunks and re-embeds a document's chunks
%%   classify_topics                 rewrites chunks' topics
%%   schedule_reembed                records a re-embed that later rewrites
%%   detect_corpus_change            writes the watermark refresh relies on; a
%%                                   forged one hides a real change
-spec operator_only() -> [atom()].
operator_only() ->
    [prune_chunks, retire_document, ingest_document, upload_knowledge,
     embed_document, classify_topics, schedule_reembed, detect_corpus_change].

%% @doc `ok' when `Procedure' (its name, as a binary) is open, or the verified
%% caller is an operator; `{error, not_an_operator}' otherwise. Compared as
%% binaries: a name never becomes an atom here.
-spec authorized(binary(), map()) -> ok | {error, not_an_operator}.
authorized(Procedure, Payload) when is_binary(Procedure) ->
    gate(lists:member(Procedure, [atom_to_binary(P) || P <- operator_only()]), Payload).

gate(false, _Payload) -> ok;
gate(true, Payload)   -> operator(verified_caller(Payload), operators()).

verified_caller(#{caller := <<_:256>> = Caller}) -> binary:encode_hex(Caller);
verified_caller(_NoVerifiedCaller)              -> undefined.

operator(undefined, _Operators) -> {error, not_an_operator};
operator(Hex, Operators)        -> member(lists:member(Hex, Operators)).

member(true)  -> ok;
member(false) -> {error, not_an_operator}.

%% A list that does not parse was refused at start (mcl_rag_service), so here
%% it can only be valid.
operators() ->
    {ok, Operators} = parse(application:get_env(mcl_rag, operators, undefined)),
    Operators.

%% @doc Node ids as 64 hex characters, separated by commas or white space, in
%% either case; returned upper-case and sorted. Unset or empty is no operators.
-spec parse(term()) -> {ok, [binary()]} | {error, malformed | {not_64_hex, binary()}}.
parse(undefined) -> {ok, []};
parse(Value) when is_list(Value) -> parse(unicode:characters_to_binary(Value));
parse(Value) when is_binary(Value) ->
    checked([string:uppercase(E) || E <- string:lexemes(Value, ?SEPARATORS)]);
parse(_Other) -> {error, malformed}.

checked(Entries) ->
    malformed([E || E <- Entries, re:run(E, ?HEX64) =:= nomatch], Entries).

malformed([], Entries)         -> {ok, lists:usort(Entries)};
malformed([Bad | _], _Entries) -> {error, {not_64_hex, Bad}}.
