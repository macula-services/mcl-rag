%%% @doc Read desk: ingest_status. How far the corpus ingestion is.
%%%
%%% Two blocks (mcl-rag#8):
%%%
%%%   - `scan': the scheduler's live view -- whether a scan is running, when
%%%     it started and finished, which repo and file it is on, how many files
%%%     of the current repo it has seen (so pending = `files_total' minus
%%%     `files_seen'), of which changed/unchanged/failed, how many it embedded,
%%%     how many chunks it wrote, and when the last file was embedded.
%%%   - `repos': for every listed repo, whether the store serves it at a head
%%%     (the head when it does) and how many of its files carry a watermark,
%%%     i.e. have been ingested at least once. A repo that is not served yet
%%%     is being caught up; its watermark count says how far.
%%%
%%% Counts only: no content, no paths beyond the file being scanned, and no
%%% signing. This desk is mcl-rag's own, deliberately NOT part of the RAG
%%% service contract (`macula_rag''s described corpus): its shape may grow,
%%% and nothing verifies it. Like `describe_corpus' it is open to any caller
%%% the station admits, and sealed like every other procedure since 0.6.0.
-module(ingest_status).

-export([status/0]).

-spec status() -> {ok, map()}.
status() ->
    {ok, #{scan => scan(), repos => repos()}}.

%%% Internal: the scheduler's live view, rendered for the wire

scan() ->
    P = refresh_corpus_scheduler:progress(),
    #{state => maps:get(state, P),
      started_at => iso(maps:get(started_ms, P, undefined)),
      finished_at => iso(maps:get(finished_ms, P, undefined)),
      duration_ms => duration(P),
      current => current(P),
      repos_total => maps:get(repos_total, P, 0),
      repos_done => maps:get(repos_done, P, 0),
      files_total => maps:get(files_total, P, 0),
      files_seen => maps:get(files_seen, P, 0),
      files_changed => maps:get(files_changed, P, 0),
      files_unchanged => maps:get(files_unchanged, P, 0),
      files_embedded => maps:get(files_embedded, P, 0),
      files_failed => maps:get(files_failed, P, 0),
      chunks_written => maps:get(chunks_written, P, 0),
      last_ingest_at => iso(maps:get(last_embedded_ms, P, undefined)),
      store_opening => maps:get(store_opening, P, false),
      next_tick_ms => maps:get(next_tick_ms, P, undefined)}.

current(P) ->
    case maps:get(current_repo, P, undefined) of
        undefined -> null;
        Repo -> #{repo => Repo, path => maps:get(current_path, P, undefined)}
    end.

duration(#{started_ms := Started} = P) when is_integer(Started) ->
    Ended = case maps:get(finished_ms, P, undefined) of
                undefined -> erlang:system_time(millisecond);
                Finished -> Finished
            end,
    Ended - Started;
duration(_NotStarted) ->
    null.

iso(undefined) -> null;
iso(Ms) when is_integer(Ms) ->
    list_to_binary(calendar:system_time_to_rfc3339(Ms, [{unit, millisecond}, {offset, "Z"}])).

%%% Internal: what the store holds per listed repo

repos() ->
    case corpus_repos_config:read() of
        {ok, Listed} -> rows(Listed, served_heads(), watermarked());
        {error, _Refused} -> []
    end.

rows(Listed, Served, Watermarked) ->
    [#{id => Id, branch => Branch,
       served => maps:is_key(Id, Served),
       head => head_of(Id, Served),
       files_watermarked => watermarked_count(Id, Watermarked)}
     || #{id := Id, branch := Branch} <- Listed].

head_of(Id, Served) ->
    case maps:find(Id, Served) of
        {ok, #{commit := Commit}} -> Commit;
        error -> null
    end.

served_heads() ->
    case rag_store:served_repos() of
        {ok, Heads} -> Heads;
        {error, _Refused} -> #{}
    end.

watermarked() ->
    case rag_store:watermarked_corpora() of
        {ok, Repos} -> Repos;
        {error, _Refused} -> []
    end.

watermarked_count(Id, Watermarked) ->
    case lists:member(Id, Watermarked) of
        false -> 0;
        true -> watermark_count(Id)
    end.

watermark_count(Id) ->
    case rag_store:watermarked_paths(Id) of
        {ok, Paths} -> length(Paths);
        {error, _Refused} -> null
    end.
