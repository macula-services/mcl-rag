%%% @doc Handler for `prune_chunks': removes a document's chunks from
%%% `rag_store' (SQLite... no — barrel now: the doc and its vector both go,
%%% atomically, via `rag_store:forget_chunk/1').
%%%
%%% `chunk_ids' on the command is an optional allowlist. Given, only ids
%%% that are BOTH requested AND actually known to belong to this document's
%%% source are pruned. Omitted, every chunk recorded against the document's
%%% `source_path' is pruned.
-module(maybe_prune_chunks).

-export([prune/1]).

%% Large enough for any one document's chunk count; `rag_store' has no
%% "unlimited" query, and a real document does not produce anywhere near
%% this many chunks at ~2000 chars each.
-define(MAX_DOCUMENT_CHUNKS, 10000).

-spec prune(map()) -> {ok, #{document_id := binary(), pruned := [binary()]}} |
                       {error, term()}.
prune(Params) when is_map(Params) ->
    case prune_chunks_v1:from_map(Params) of
        {ok, Cmd}      -> prune_cmd(Cmd);
        {error, _} = E -> E
    end.

prune_cmd(Cmd) ->
    case prune_chunks_v1:validate(Cmd) of
        ok         -> do_prune(Cmd);
        {error, R} -> {error, R}
    end.

do_prune(Cmd) ->
    Id = prune_chunks_v1:get_document_id(Cmd),
    case rag_store:get_source(Id) of
        {ok, #{source_path := SourcePath}} -> prune_source(Id, SourcePath, Cmd);
        {error, not_found}                 -> {error, not_ingested}
    end.

prune_source(Id, SourcePath, Cmd) ->
    case rag_store:list_chunks_by_source(SourcePath, ?MAX_DOCUMENT_CHUNKS) of
        {ok, Chunks}   -> forget_targets(Id, Chunks, Cmd);
        {error, _} = E -> E
    end.

forget_targets(Id, Chunks, Cmd) ->
    Known = [maps:get(chunk_id, C) || C <- Chunks],
    ToPrune = target_ids(prune_chunks_v1:get_chunk_ids(Cmd), Known),
    lists:foreach(fun rag_store:forget_chunk/1, ToPrune),
    {ok, #{document_id => Id, pruned => ToPrune}}.

%% No allowlist -> prune everything known. An allowlist -> the intersection,
%% so a caller can only ever prune ids this document's source actually has.
target_ids(undefined, Known) -> Known;
target_ids(Requested, Known) -> [Id || Id <- Requested, lists:member(Id, Known)].
