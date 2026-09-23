%%% @doc Parameters for `upload_knowledge'.
%%%
%%% Accepts a raw document (file bytes) + metadata. The handler chunks
%%% it via `markdown_chunker', embeds each chunk via `rag_embedder' (in
%%% a worker process, not inside `rag_store'), and writes each chunk
%%% with its vector to `rag_store'. The server owns chunking and
%%% embedding — the caller just sends raw content.
%%%
%%% `deposited_by' -- see `add_knowledge_v1''s own doc for the full
%%% reasoning, identical here: read via `mcl_om_wire:caller/1', not
%%% from the caller's own payload, wire-authenticated and unspoofable,
%%% distinct from `source_path' (a caller-chosen label, kept as-is).
%%%
%%% Not an evoq command: same rationale as `ingest_document'.
-module(upload_knowledge_v1).

-export([new/1, from_map/1, validate/1]).
-export([get_document_id/1, get_source_path/1, get_source_type/1, get_raw_bytes/1,
          get_deposited_by/1]).

-record(upload_knowledge_v1, {
    document_id  :: binary() | undefined,
    source_path  :: binary() | undefined,
    source_type  :: binary() | undefined,
    raw_bytes    :: binary() | undefined,
    deposited_by :: binary() | undefined
}).

-opaque t() :: #upload_knowledge_v1{}.
-export_type([t/0]).

-spec new(map()) -> {ok, t()} | {error, term()}.
new(#{document_id := Id} = Params) ->
    {ok, #upload_knowledge_v1{
        document_id  = Id,
        source_path  = maps:get(source_path, Params, undefined),
        source_type  = maps:get(source_type, Params, undefined),
        raw_bytes    = maps:get(raw_bytes, Params, undefined),
        deposited_by = maps:get(deposited_by, Params, undefined)
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
    {ok, #upload_knowledge_v1{
        document_id  = Id,
        source_path  = mcl_om_wire:field(<<"source_path">>, Map),
        source_type  = mcl_om_wire:field(<<"source_type">>, Map),
        raw_bytes    = mcl_om_wire:field(<<"raw_bytes">>, Map),
        deposited_by = mcl_om_wire:caller(Map)
    }}.

-spec validate(t()) -> ok | {error, term()}.
validate(#upload_knowledge_v1{document_id = undefined}) -> {error, missing_document_id};
validate(#upload_knowledge_v1{raw_bytes = undefined}) -> {error, missing_raw_bytes};
validate(#upload_knowledge_v1{raw_bytes = <<>>}) -> {error, empty_content};
validate(_) -> ok.

-spec get_document_id(t()) -> binary() | undefined.
get_document_id(#upload_knowledge_v1{document_id = V}) -> V.

-spec get_source_path(t()) -> binary() | undefined.
get_source_path(#upload_knowledge_v1{source_path = V}) -> V.

-spec get_source_type(t()) -> binary() | undefined.
get_source_type(#upload_knowledge_v1{source_type = V}) -> V.

-spec get_raw_bytes(t()) -> binary() | undefined.
get_raw_bytes(#upload_knowledge_v1{raw_bytes = V}) -> V.

%% @doc See `add_knowledge_v1:get_deposited_by/1' -- identical contract.
-spec get_deposited_by(t()) -> binary() | undefined.
get_deposited_by(#upload_knowledge_v1{deposited_by = V}) -> V.
