%%% @doc Parameters for `embed_document'.
%%%
%%% Just a document id: chunking and embedding both read the raw content
%%% `ingest_document' already recorded against this document in `rag_store'
%%% (as a source record), not from anything the caller passes in here.
%%% There is exactly one chunker (`markdown_chunker') and one configured
%%% embedding model in this deployment (see `maybe_embed_document'), so
%%% there's nothing else to parameterize yet — a `model_id'/`dim' input
%%% field would be speculative until multi-model support is real.
%%%
%%% Not an evoq command: `embed_document' writes straight to `rag_store'.
%%% Chunks and vectors are a deterministic function of (source text,
%%% chunker, embedding model), not a business fact anyone decided, so
%%% there is nothing here worth event-sourcing or replaying from history.
-module(embed_document_v1).

-export([new/1, from_map/1, validate/1]).
-export([get_document_id/1]).

-record(embed_document_v1, {
    document_id :: binary() | undefined
}).

-opaque t() :: #embed_document_v1{}.
-export_type([t/0]).

-spec new(map()) -> {ok, t()} | {error, term()}.
new(#{document_id := Id}) ->
    {ok, #embed_document_v1{document_id = Id}};
new(_) ->
    {error, missing_document_id}.

%% Uses mcl_om_wire:field/2, not a hard #{<<"document_id">> := Id}
%% pattern -- macula's frame decoder atomizes an inbound payload's keys
%% (binary_to_existing_atom), so a hard binary-key match here silently
%% never matches a real mesh caller's payload. See mcl_om_wire's own
%% moduledoc and hecate-corpus's antipatterns skill for the full story.
-spec from_map(map()) -> {ok, t()} | {error, term()}.
from_map(Map) when is_map(Map) ->
    from_map_(mcl_om_wire:field(<<"document_id">>, Map));
from_map(_) ->
    {error, missing_document_id}.

from_map_(undefined) -> {error, missing_document_id};
from_map_(Id)        -> {ok, #embed_document_v1{document_id = Id}}.

-spec validate(t()) -> ok | {error, term()}.
validate(#embed_document_v1{document_id = undefined}) -> {error, missing_document_id};
validate(_) -> ok.

-spec get_document_id(t()) -> binary() | undefined.
get_document_id(#embed_document_v1{document_id = V}) -> V.
