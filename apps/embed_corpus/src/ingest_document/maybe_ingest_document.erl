%%% @doc Handler for `ingest_document': records a document's raw content as
%%% a source record in `rag_store'. `embed_document' reads it back to
%%% chunk + embed it.
-module(maybe_ingest_document).

-export([ingest/1]).

-spec ingest(map()) -> {ok, #{document_id := binary()}} | {error, term()}.
ingest(Params) when is_map(Params) ->
    case ingest_document_v1:from_map(Params) of
        {ok, Cmd}      -> ingest_cmd(Cmd);
        {error, _} = E -> E
    end.

ingest_cmd(Cmd) ->
    case ingest_document_v1:validate(Cmd) of
        ok         -> do_ingest(Cmd);
        {error, R} -> {error, R}
    end.

do_ingest(Cmd) ->
    Id = ingest_document_v1:get_document_id(Cmd),
    Source = #{
        document_id => Id,
        source_path => ingest_document_v1:get_source_path(Cmd),
        source_type => ingest_document_v1:get_source_type(Cmd),
        raw_bytes   => ingest_document_v1:get_raw_bytes(Cmd)
    },
    case rag_store:upsert_source(Source) of
        ok             -> {ok, #{document_id => Id}};
        {error, _} = E -> E
    end.
