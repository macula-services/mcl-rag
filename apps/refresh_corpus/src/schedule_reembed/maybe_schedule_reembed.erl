%%% @doc Handler for `schedule_reembed_v1' -- records a re-embed request
%%% durably, does not perform the re-embed itself.
%%%
%%% This command carries a `source_path', not a `document_id' (a corpus
%%% scan has paths on hand, not the caller-chosen ids `ingest_document'
%%% assigned) -- resolved via `rag_store:find_source_by_path/1', the
%%% same lookup `detect_corpus_change' would use to confirm a source is
%%% actually known before scheduling work against it. Unknown path ->
%%% `{error, not_ingested}', same shape `maybe_embed_document' already
%%% uses for the same situation.
%%%
%%% Deliberately NOT built here: anything that actually consumes these
%%% requests and calls `maybe_embed_document:embed/1' when due. That's
%%% a standing background worker (a poll loop over `priority'/
%%% `scheduled_at'), a different, separable piece of infrastructure from
%%% "record that a re-embed was requested" -- this slice's own job, per
%%% its command's fields. Recorded requests are queryable in `rag_store'
%%% (`type = reembed_request', `status = pending') once that worker
%%% exists; nothing here fabricates polling/scheduling behavior that
%%% isn't real yet.
-module(maybe_schedule_reembed).

-export([schedule/1]).

-spec schedule(map()) -> {ok, #{request_id := binary(), document_id := binary()}} |
                          {error, term()}.
schedule(Params) when is_map(Params) ->
    case schedule_reembed_v1:from_map(Params) of
        {ok, Cmd}      -> schedule_cmd(Cmd);
        {error, _} = E -> E
    end.

schedule_cmd(Cmd) ->
    case schedule_reembed_v1:validate(Cmd) of
        ok         -> do_schedule(Cmd);
        {error, R} -> {error, R}
    end.

do_schedule(Cmd) ->
    SourcePath = schedule_reembed_v1:get_source_path(Cmd),
    request_for_source(rag_store:find_source_by_path(SourcePath), Cmd).

request_for_source({error, not_found}, _Cmd) ->
    {error, not_ingested};
request_for_source({ok, #{document_id := DocId}}, Cmd) ->
    %% priority/scheduled_at are optional on the command -- `undefined'
    %% (Erlang's "absent," not barrel's own `nil') would crash barrel's
    %% write path if passed through as a raw atom, so an absent field
    %% is left OUT of the map entirely here; rag_store's own
    %% `maps:get(_, _, <<>>)' defaults fill it in from there, same
    %% pattern `put_source_doc' already uses for its own optional
    %% fields.
    Req0 = #{
        document_id => DocId,
        corpus_id   => schedule_reembed_v1:get_corpus_id(Cmd),
        source_path => schedule_reembed_v1:get_source_path(Cmd)
    },
    Req = with_defined(priority, schedule_reembed_v1:get_priority(Cmd),
            with_defined(scheduled_at, schedule_reembed_v1:get_scheduled_at(Cmd), Req0)),
    request_recorded(rag_store:put_reembed_request(Req), DocId).

with_defined(_Key, undefined, Map) -> Map;
with_defined(Key, Value, Map)      -> Map#{Key => Value}.

request_recorded({ok, #{request_id := ReqId}}, DocId) ->
    {ok, #{request_id => ReqId, document_id => DocId}};
request_recorded({error, _} = E, _DocId) ->
    E.
