%%% @doc Parameters for `retire_document'.
%%%
%%% `document_id' names the document to retire; `reason' is free text
%%% for the operator's own log line (not stored: nothing here is
%%% event-sourced, see `embed_document_v1' for why).
-module(retire_document_v1).

-export([new/1, from_map/1, validate/1]).
-export([get_document_id/1, get_reason/1]).

-record(retire_document_v1, {
    document_id :: binary() | undefined,
    reason :: binary() | undefined
}).

-opaque t() :: #retire_document_v1{}.
-export_type([t/0]).

-spec new(map()) -> {ok, t()} | {error, term()}.
new(#{document_id := Id} = Params) ->
    {ok, #retire_document_v1{
        document_id = Id,
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
    {ok, #retire_document_v1{
        document_id = Id,
        reason = mcl_om_wire:field(<<"reason">>, Map)
    }}.

-spec validate(t()) -> ok | {error, term()}.
validate(#retire_document_v1{document_id = undefined}) -> {error, missing_document_id};
validate(_) -> ok.

-spec get_document_id(t()) -> binary() | undefined.
get_document_id(#retire_document_v1{document_id = V}) -> V.

-spec get_reason(t()) -> binary() | undefined.
get_reason(#retire_document_v1{reason = V}) -> V.
