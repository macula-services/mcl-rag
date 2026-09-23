%%% @doc Parameters for `ingest_document'.
%%%
%%% Records a document's raw content in `rag_store' as a source record.
%%% `embed_document' reads it back from there to chunk + embed it —
%%% ingest and embed stay two calls so a document can be re-embedded (new
%%% model, new chunk size) without resubmitting its raw bytes.
%%%
%%% Not an evoq command: `ingest_document' writes straight to `rag_store'.
%%% See `embed_document_v1' for why this desk isn't event-sourced.
-module(ingest_document_v1).

-export([new/1, from_map/1, validate/1]).
-export([get_document_id/1, get_source_path/1, get_source_type/1, get_raw_bytes/1]).

-record(ingest_document_v1, {
    document_id :: binary() | undefined,
    source_path :: binary() | undefined,
    source_type :: binary() | undefined,
    raw_bytes :: binary() | undefined
}).

-opaque t() :: #ingest_document_v1{}.
-export_type([t/0]).

-spec new(map()) -> {ok, t()} | {error, term()}.
new(#{document_id := Id} = Params) ->
    {ok, #ingest_document_v1{
        document_id = Id,
        source_path = maps:get(source_path, Params, undefined),
        source_type = maps:get(source_type, Params, undefined),
        raw_bytes = maps:get(raw_bytes, Params, undefined)
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
    {ok, #ingest_document_v1{
        document_id = Id,
        source_path = mcl_om_wire:field(<<"source_path">>, Map),
        source_type = mcl_om_wire:field(<<"source_type">>, Map),
        raw_bytes = mcl_om_wire:field(<<"raw_bytes">>, Map)
    }}.

-spec validate(t()) -> ok | {error, term()}.
validate(#ingest_document_v1{document_id = undefined}) -> {error, missing_document_id};
validate(_) -> ok.

-spec get_document_id(t()) -> binary() | undefined.
get_document_id(#ingest_document_v1{document_id = V}) -> V.

-spec get_source_path(t()) -> binary() | undefined.
get_source_path(#ingest_document_v1{source_path = V}) -> V.

-spec get_source_type(t()) -> binary() | undefined.
get_source_type(#ingest_document_v1{source_type = V}) -> V.

-spec get_raw_bytes(t()) -> binary() | undefined.
get_raw_bytes(#ingest_document_v1{raw_bytes = V}) -> V.
