%%% @doc Command `detect_corpus_change_v1`.
%%%
%%% Generated stub. Add validation in `maybe_detect_corpus_change` once the slice
%%% has real business rules.
-module(detect_corpus_change_v1).
-behaviour(evoq_command).

-export([command_type/0]).
-export([new/1, from_map/1, validate/1, to_map/1]).
-export([stream_id/1]).
-export([get_corpus_id/1, get_source_path/1, get_kind/1, get_diff_hash/1]).

-record(detect_corpus_change_v1, {
    corpus_id :: binary() | undefined,
    source_path :: binary() | undefined,
    kind :: binary() | undefined,
    diff_hash :: binary() | undefined
}).

-opaque t() :: #detect_corpus_change_v1{}.
-export_type([t/0]).

-spec command_type() -> atom().
command_type() -> detect_corpus_change_v1.

-spec new(map()) -> {ok, t()} | {error, term()}.
new(#{corpus_id := Id} = Params) ->
    {ok, #detect_corpus_change_v1{
        corpus_id = Id,
        source_path = maps:get(source_path, Params, undefined),
        kind = maps:get(kind, Params, undefined),
        diff_hash = maps:get(diff_hash, Params, undefined)
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
    {ok, #detect_corpus_change_v1{
        corpus_id = Id,
        source_path = mcl_om_wire:field(<<"source_path">>, Map),
        kind = mcl_om_wire:field(<<"kind">>, Map),
        diff_hash = mcl_om_wire:field(<<"diff_hash">>, Map)
    }}.

%% `source_path'/`diff_hash' are required here, not optional as the
%% record type suggests -- both are load-bearing for
%% `maybe_detect_corpus_change''s actual comparison (which source, and
%% against what hash), not just descriptive metadata. `kind' stays
%% optional; nothing branches on it yet.
-spec validate(t()) -> ok | {error, term()}.
validate(#detect_corpus_change_v1{corpus_id = undefined}) -> {error, missing_aggregate_id};
validate(#detect_corpus_change_v1{source_path = undefined}) -> {error, missing_source_path};
validate(#detect_corpus_change_v1{diff_hash = undefined}) -> {error, missing_diff_hash};
validate(_) -> ok.

-spec to_map(t()) -> map().
to_map(#detect_corpus_change_v1{} = Cmd) ->
    #{
        command_type => detect_corpus_change_v1,
        corpus_id => Cmd#detect_corpus_change_v1.corpus_id,
        source_path => Cmd#detect_corpus_change_v1.source_path,
        kind => Cmd#detect_corpus_change_v1.kind,
        diff_hash => Cmd#detect_corpus_change_v1.diff_hash
    }.

-spec stream_id(t()) -> binary().
stream_id(#detect_corpus_change_v1{corpus_id = Id}) ->
    <<"corpus-", Id/binary>>.

-spec get_corpus_id(t()) -> binary() | undefined.
get_corpus_id(#detect_corpus_change_v1{corpus_id = V}) -> V.

-spec get_source_path(t()) -> binary() | undefined.
get_source_path(#detect_corpus_change_v1{source_path = V}) -> V.

-spec get_kind(t()) -> binary() | undefined.
get_kind(#detect_corpus_change_v1{kind = V}) -> V.

-spec get_diff_hash(t()) -> binary() | undefined.
get_diff_hash(#detect_corpus_change_v1{diff_hash = V}) -> V.
