%%% @doc Parameters for `add_knowledge'.
%%%
%%% Accepts a text snippet + optional metadata (source_label, topics).
%%% Designed for conversational deposits: an agent learns something
%%% during a session and pushes it directly. The server may chunk if
%%% the text is long, but the common case is a paragraph or two —
%%% one chunk, one embed, one store.
%%%
%%% `deposited_by' is NOT read from the caller's own payload: it comes
%%% from `mcl_om_wire:caller/1', which reads the `caller' key
%%% `macula_station_link:handle_inbound_call/2' merges into every mesh
%%% payload after decoding, from the CALL frame's own wire-authenticated
%%% field (macula >= 10.15.0; see that changelog entry and
%%% `macula_station_link.erl''s own `with_caller/2'). That merge
%%% deterministically overwrites any same-named key a caller's own
%%% payload supplied, so a caller cannot spoof `deposited_by' by naming
%%% a field the same thing -- distinct from `source_label', which is
%%% exactly that: a label the depositing agent chose for itself, kept
%%% for grouping, never attribution. `deposited_by' is `undefined' for
%%% anything that reaches `from_map/1' without going through a real
%%% inbound mesh call (`dispatch/2', this module's own `new/1', or a
%%% pre-10.15.0 peer) -- there is no wire identity to attach in any of
%%% those cases, so nothing is invented to fill it.
%%%
%%% Not an evoq command: same rationale as `ingest_document'.
-module(add_knowledge_v1).

-export([new/1, from_map/1, validate/1]).
-export([get_text/1, get_source_label/1, get_topics/1, get_deposited_by/1]).

-record(add_knowledge_v1, {
    text         :: binary() | undefined,
    source_label :: binary() | undefined,
    topics       :: [binary()] | undefined,
    deposited_by :: binary() | undefined
}).

-opaque t() :: #add_knowledge_v1{}.
-export_type([t/0]).

-spec new(map()) -> {ok, t()} | {error, term()}.
new(#{text := Text} = Params) ->
    {ok, #add_knowledge_v1{
        text         = Text,
        source_label = maps:get(source_label, Params, undefined),
        topics       = maps:get(topics, Params, undefined),
        deposited_by = maps:get(deposited_by, Params, undefined)
    }};
new(_) ->
    {error, missing_text}.

%% Uses mcl_om_wire:field/2, not a hard #{<<"text">> := Text}
%% pattern -- macula's frame decoder atomizes an inbound payload's keys
%% (binary_to_existing_atom), so a hard binary-key match here silently
%% never matches a real mesh caller's payload. See mcl_om_wire's own
%% moduledoc and hecate-corpus's antipatterns skill for the full story.
-spec from_map(map()) -> {ok, t()} | {error, term()}.
from_map(Map) when is_map(Map) ->
    from_map_(mcl_om_wire:field(<<"text">>, Map), Map);
from_map(_) ->
    {error, missing_text}.

from_map_(undefined, _Map) ->
    {error, missing_text};
from_map_(Text, Map) ->
    {ok, #add_knowledge_v1{
        text         = Text,
        source_label = mcl_om_wire:field(<<"source_label">>, Map),
        topics       = mcl_om_wire:field(<<"topics">>, Map),
        deposited_by = mcl_om_wire:caller(Map)
    }}.

-spec validate(t()) -> ok | {error, term()}.
validate(#add_knowledge_v1{text = undefined}) -> {error, missing_text};
validate(#add_knowledge_v1{text = <<>>}) -> {error, empty_text};
validate(_) -> ok.

-spec get_text(t()) -> binary() | undefined.
get_text(#add_knowledge_v1{text = V}) -> V.

-spec get_source_label(t()) -> binary() | undefined.
get_source_label(#add_knowledge_v1{source_label = V}) -> V.

-spec get_topics(t()) -> [binary()] | undefined.
get_topics(#add_knowledge_v1{topics = V}) -> V.

%% @doc The wire-authenticated pubkey (32 raw bytes) of whoever's mesh
%% call this deposit arrived on, or `undefined' -- see this module's own
%% doc for exactly when that's the case. Raw bytes, not hex: `maybe_add_knowledge'
%% hex-encodes at the point of storage, the same convention this
%% service already uses for chunk/document ids.
-spec get_deposited_by(t()) -> binary() | undefined.
get_deposited_by(#add_knowledge_v1{deposited_by = V}) -> V.
