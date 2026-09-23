%%% @doc Handler for `classify_topics': classifies a document's chunks
%%% into topic labels using an LLM API, then tags each chunk in
%%% `rag_store' with the resulting topics.
%%%
%%% Default mode is document-level: samples the first few chunks,
%%% classifies once, tags all chunks with the same topic set. This is
%%% one API call per document — cheaper and coherent for documents
%%% that are about one thing (the common case).
%%%
%%% Chunk-level mode (`per_chunk' in the params) classifies each chunk
%%% individually — more precise for documents spanning many topics,
%%% but N API calls for N chunks.
%%%
%%% Not event-sourced: topic labels are a derived classification, not a
%%% business fact. Same rationale as `embed_document'.
-module(maybe_classify_topics).

-export([classify/1]).
%% mode/1 exported for unit testability, matching this codebase's own
%% convention for pure helpers (see mcl_om_capabilities.erl).
-export([mode/1]).

-define(SAMPLE_CHUNK_COUNT, 3).
-define(SAMPLE_MAX_CHARS, 2000).

-spec classify(map()) -> {ok, #{document_id := binary(), topics => [binary()], tagged => non_neg_integer()}} |
                          {error, term()}.
classify(Params) when is_map(Params) ->
    case classify_topics_v1:from_map(Params) of
        {ok, Cmd}      -> classify_cmd(Cmd, Params);
        {error, _} = E -> E
    end.

classify_cmd(Cmd, Params) ->
    case classify_topics_v1:validate(Cmd) of
        ok         -> do_classify(Cmd, Params);
        {error, R} -> {error, R}
    end.

do_classify(Cmd, Params) ->
    DocId = classify_topics_v1:get_document_id(Cmd),
    MaxTopics = classify_topics_v1:get_max_topics(Cmd),
    case rag_store:get_source_content(DocId) of
        {error, not_found} -> {error, not_ingested};
        {ok, Content}      -> classify_chunks(Content, DocId, MaxTopics, Params)
    end.

classify_chunks(#{source_path := SourcePath}, DocId, MaxTopics, Params) ->
    Path = path_or_id(SourcePath, DocId),
    case rag_store:list_chunks_by_source(Path, 500) of
        {ok, []}   -> {error, not_embedded};
        {ok, Chunks} -> classify_and_tag(mode(Params), Chunks, MaxTopics, DocId)
    end.

classify_and_tag(document, Chunks, MaxTopics, DocId) ->
    Sample = sample_text(Chunks),
    case rag_topic_classifier:classify(Sample, MaxTopics) of
        {ok, Topics} -> tag_document(DocId, Chunks, Topics);
        {error, _} = E -> E
    end;
classify_and_tag(per_chunk, Chunks, MaxTopics, DocId) ->
    {Tagged, AllTopics} = classify_each(Chunks, MaxTopics),
    {ok, #{document_id => DocId, topics => lists:usort(AllTopics), tagged => Tagged}}.

tag_document(DocId, Chunks, Topics) ->
    Tagged = tag_all(Chunks, Topics),
    {ok, #{document_id => DocId, topics => Topics, tagged => Tagged}}.

classify_each(Chunks, MaxTopics) ->
    lists:foldl(fun(Chunk, {Count, Acc}) ->
        classify_one_chunk(Chunk, MaxTopics, Count, Acc)
    end, {0, []}, Chunks).

classify_one_chunk(Chunk, MaxTopics, Count, Acc) ->
    Content = maps:get(content, Chunk, <<>>),
    case rag_topic_classifier:classify(Content, MaxTopics) of
        {ok, Topics} ->
            ok = tag_chunk(Chunk, Topics),
            {Count + 1, Acc ++ Topics};
        {error, Reason} ->
            logger:warning("[classify_topics] chunk ~s failed: ~p",
                           [maps:get(chunk_id, Chunk, <<>>), Reason]),
            {Count, Acc}
    end.

tag_all(Chunks, Topics) ->
    lists:foldl(fun(Chunk, Count) -> count_tag(Chunk, Topics, Count) end, 0, Chunks).

count_tag(Chunk, Topics, Count) ->
    case tag_chunk(Chunk, Topics) of
        ok          -> Count + 1;
        {error, _}  -> Count
    end.

tag_chunk(#{chunk_id := ChunkId}, Topics) ->
    rag_store:tag_chunk(ChunkId, Topics);
tag_chunk(_, _Topics) ->
    {error, no_chunk_id}.

sample_text(Chunks) ->
    First = lists:sublist(Chunks, ?SAMPLE_CHUNK_COUNT),
    Contents = [maps:get(content, C, <<>>) || C <- First],
    Combined = iolist_to_binary(lists:join(<<"\n\n">>, Contents)),
    case byte_size(Combined) > ?SAMPLE_MAX_CHARS of
        true  -> binary:part(Combined, 0, ?SAMPLE_MAX_CHARS);
        false -> Combined
    end.

path_or_id(<<>>, Id) -> Id;
path_or_id(Path, _)   -> Path.

%% Uses mcl_om_wire:field/2, not maps:get(<<"mode">>, ...) -- macula's
%% frame decoder atomizes an inbound payload's keys (binary_to_existing_atom),
%% so a hard binary-key lookup here silently never sees a real mesh
%% caller's `mode' field. See mcl_om_wire's own moduledoc and
%% hecate-corpus's antipatterns skill for the full story.
mode(Params) ->
    case mcl_om_wire:field(<<"mode">>, Params, document) of
        <<"per_chunk">> -> per_chunk;
        _                -> document
    end.
