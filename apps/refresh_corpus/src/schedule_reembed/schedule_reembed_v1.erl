%%% @doc Command `schedule_reembed_v1`.
%%%
%%% Generated stub. Add validation in `maybe_schedule_reembed` once the slice
%%% has real business rules.
-module(schedule_reembed_v1).
-behaviour(evoq_command).

-export([command_type/0]).
-export([new/1, from_map/1, validate/1, to_map/1]).
-export([stream_id/1]).
-export([get_corpus_id/1, get_source_path/1, get_priority/1, get_scheduled_at/1]).

-record(schedule_reembed_v1, {
    corpus_id :: binary() | undefined,
    source_path :: binary() | undefined,
    priority :: binary() | undefined,
    scheduled_at :: binary() | undefined
}).

-opaque t() :: #schedule_reembed_v1{}.
-export_type([t/0]).

-spec command_type() -> atom().
command_type() -> schedule_reembed_v1.

-spec new(map()) -> {ok, t()} | {error, term()}.
new(#{corpus_id := Id} = Params) ->
    {ok, #schedule_reembed_v1{
        corpus_id = Id,
        source_path = maps:get(source_path, Params, undefined),
        priority = maps:get(priority, Params, undefined),
        scheduled_at = maps:get(scheduled_at, Params, undefined)
    }};
new(_) ->
    {error, missing_aggregate_id}.

%% Uses mcl_om_wire:field/2, not a hard #{<<"corpus_id">> := Id}
%% pattern -- macula's frame decoder atomizes an inbound payload's keys
%% (binary_to_existing_atom), so a hard binary-key match here silently
%% never matches a real mesh caller's payload. See mcl_om_wire's own
%% moduledoc and hecate-corpus's antipatterns skill for the full story.
-spec from_map(map()) -> {ok, t()} | {error, term()}.
from_map(Map) when is_map(Map) ->
    from_map_(mcl_om_wire:field(<<"corpus_id">>, Map), Map);
from_map(_) ->
    {error, missing_aggregate_id}.

from_map_(undefined, _Map) ->
    {error, missing_aggregate_id};
from_map_(Id, Map) ->
    {ok, #schedule_reembed_v1{
        corpus_id = Id,
        source_path = mcl_om_wire:field(<<"source_path">>, Map),
        priority = mcl_om_wire:field(<<"priority">>, Map),
        scheduled_at = mcl_om_wire:field(<<"scheduled_at">>, Map)
    }}.

%% `source_path' is load-bearing for `maybe_schedule_reembed' -- it's
%% how the target document gets found (this command carries no
%% `document_id' of its own). `priority'/`scheduled_at' stay optional,
%% informational fields on the recorded request.
-spec validate(t()) -> ok | {error, term()}.
validate(#schedule_reembed_v1{corpus_id = undefined}) -> {error, missing_aggregate_id};
validate(#schedule_reembed_v1{source_path = undefined}) -> {error, missing_source_path};
validate(_) -> ok.

-spec to_map(t()) -> map().
to_map(#schedule_reembed_v1{} = Cmd) ->
    #{
        command_type => schedule_reembed_v1,
        corpus_id => Cmd#schedule_reembed_v1.corpus_id,
        source_path => Cmd#schedule_reembed_v1.source_path,
        priority => Cmd#schedule_reembed_v1.priority,
        scheduled_at => Cmd#schedule_reembed_v1.scheduled_at
    }.

-spec stream_id(t()) -> binary().
stream_id(#schedule_reembed_v1{corpus_id = Id}) ->
    <<"corpus-", Id/binary>>.

-spec get_corpus_id(t()) -> binary() | undefined.
get_corpus_id(#schedule_reembed_v1{corpus_id = V}) -> V.

-spec get_source_path(t()) -> binary() | undefined.
get_source_path(#schedule_reembed_v1{source_path = V}) -> V.

-spec get_priority(t()) -> binary() | undefined.
get_priority(#schedule_reembed_v1{priority = V}) -> V.

-spec get_scheduled_at(t()) -> binary() | undefined.
get_scheduled_at(#schedule_reembed_v1{scheduled_at = V}) -> V.
