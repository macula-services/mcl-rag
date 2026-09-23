%%% @doc Parameters for `prune_chunks'.
%%%
%%% `chunk_ids' is an optional allowlist: given, only ids that are BOTH
%%% requested AND actually known to belong to this document's source are
%%% pruned — a stray or foreign id in the request can't be used to prune
%%% something this document doesn't own. Omitted, every chunk recorded
%%% against this document's `source_path' is pruned.
%%%
%%% Not an evoq command: `prune_chunks' writes straight to `rag_store'.
%%% See `embed_document_v1' for why this desk isn't event-sourced.
-module(prune_chunks_v1).

-export([new/1, from_map/1, validate/1]).
-export([get_document_id/1, get_chunk_ids/1, get_reason/1]).

-record(prune_chunks_v1, {
    document_id :: binary() | undefined,
    chunk_ids :: [binary()] | undefined,
    reason :: binary() | undefined
}).

-opaque t() :: #prune_chunks_v1{}.
-export_type([t/0]).

-spec new(map()) -> {ok, t()} | {error, term()}.
new(#{document_id := Id} = Params) ->
    {ok, #prune_chunks_v1{
        document_id = Id,
        chunk_ids = maps:get(chunk_ids, Params, undefined),
        reason = maps:get(reason, Params, undefined)
    }};
new(_) ->
    {error, missing_document_id}.

%% Uses mcl_om_wire:field/2, not a hard #{<<"document_id">> := Id}
%% pattern -- macula's frame decoder atomizes an inbound payload's keys
%% (binary_to_existing_atom), so a hard binary-key match here silently
%% never matches a real mesh caller's payload. See mcl_om_wire's own
%% moduledoc and hecate-corpus's antipatterns skill for the full story.
-spec from_map(map()) -> {ok, t()} | {error, term()}.
from_map(Map) when is_map(Map) ->
    from_map_(mcl_om_wire:field(<<"document_id">>, Map), Map);
from_map(_) ->
    {error, missing_document_id}.

from_map_(undefined, _Map) ->
    {error, missing_document_id};
from_map_(Id, Map) ->
    {ok, #prune_chunks_v1{
        document_id = Id,
        chunk_ids = mcl_om_wire:field(<<"chunk_ids">>, Map),
        reason = mcl_om_wire:field(<<"reason">>, Map)
    }}.

-spec validate(t()) -> ok | {error, term()}.
validate(#prune_chunks_v1{document_id = undefined}) -> {error, missing_document_id};
validate(_) -> ok.

-spec get_document_id(t()) -> binary() | undefined.
get_document_id(#prune_chunks_v1{document_id = V}) -> V.

-spec get_chunk_ids(t()) -> [binary()] | undefined.
get_chunk_ids(#prune_chunks_v1{chunk_ids = V}) -> V.

-spec get_reason(t()) -> binary() | undefined.
get_reason(#prune_chunks_v1{reason = V}) -> V.
