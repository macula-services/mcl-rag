%%% @doc Closes the loop `detect_corpus_change'/`schedule_reembed' left
%%% open: something has to actually walk the corpus and call them.
%%% Ticks every `?POLL_INTERVAL_MS', re-reads
%%% `corpus_repos_config:read/0' (the same config `corpus_git_sync'
%%% reads, independently -- see that module's own doc for why these
%%% two loops don't coordinate), and for every configured repo, hashes
%%% every file under its local path. For each one whose hash differs
%%% from its last-known watermark:
%%%
%%%   1. Calls `maybe_schedule_reembed:schedule/1' to durably record the
%%%      request (the queue `schedule_reembed_v1' already exists for,
%%%      per its own module doc -- kept for the observability/audit
%%%      trail it gives, even though this same tick also does step 2).
%%%   2. Refreshes it immediately: `rag_store:upsert_source/1' with the
%%%      file's current bytes, then `maybe_embed_document:embed/1' --
%%%      which re-reads whatever `upsert_source' just wrote and
%%%      re-chunks/re-embeds from there. Works identically for a file
%%%      that already existed and one that never has (`upsert_source'
%%%      creates it either way), so there is no separate "new file"
%%%      branch.
%%%
%%% `document_id'/`source_path' are `<<RepoId/binary, "/",
%%% RelPath/binary>>', not the bare relative path: `rag_store''s source
%%% storage keys on `document_id' alone with no repo-scoping of its
%%% own, so two configured repos sharing a same-named file (both have
%%% a `README.md', say) would silently overwrite each other's record
%%% without this. `maybe_schedule_reembed:schedule/1' looks its target
%%% up by this same `source_path' value (via
%%% `rag_store:find_source_by_path/1'), so it must match exactly what
%%% `upsert_source' stored under -- both call sites use the same
%%% namespaced id for that reason, not just for the storage-collision
%%% one. Contract-visible: `mcl-rag.get_document_verbatim' now needs
%%% `"<repo-id>/<relative-path>"', e.g. `"macula/README.md"'.
%%%
%%% Deliberately immediate, not a separately-scheduled async drain: a
%%% markdown-sized re-ingest is cheap (a handful of embedder calls per
%%% file, made in this process by `rag_chunk_embedder' underneath
%%% `maybe_embed_document', then one vector-carrying write per chunk),
%%% so there is no real workload here that needs decoupling detection
%%% from processing across a durable backlog. If that changes, a
%%% consumer reading `type = reembed_request' records back out of
%%% `rag_store' is a natural, separate addition -- not built ahead of
%%% actually needing it.
%%%
%%% A refresh that fails (embedder unreachable, store error) does not
%%% stay failed until the file next changes: `detect_corpus_change' has
%%% already recorded the file's new hash by then, so this module resets
%%% that watermark to `?RETRY_WATERMARK' and the next tick sees the
%%% file as changed again.
%%%
%%% `?INDEX_GENERATION' salts every hash. Bump it when what a refresh
%%% WRITES changes shape (2026-09-02: chunks gained their vector), so
%%% every file re-ingests exactly once on the next tick and a store
%%% built by the old code catches up without anyone touching the corpus.
%%%
%%% Lives here (service-level infrastructure, per `mcl_rag_sup''s
%%% own module doc), not inside `refresh_corpus' despite otherwise
%%% being that app's own concern: it calls `corpus_repos_config', a
%%% top-level app module (shared with `corpus_git_sync', so both loops
%%% read the exact same repo list and path derivation), and this
%%% umbrella's dependency direction runs from the top app into the
%%% sub-apps, never the reverse. A standing poller spanning every
%%% configured repo is also a different shape from `refresh_corpus''s
%%% other modules, which are single-RPC desks (`detect_corpus_change',
%%% `schedule_reembed') this one happens to call in a loop.
-module(refresh_corpus_scheduler).
-behaviour(gen_server).

-export([start_link/0, scan/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(POLL_INTERVAL_MS, 120000).
-define(GLOB, "**/*.md").
-define(INDEX_GENERATION, <<"vectors-v1:">>).
-define(RETRY_WATERMARK, <<"retry">>).

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    schedule_tick(0),
    {ok, #{}}.

handle_info(tick, State) ->
    scan(),
    schedule_tick(?POLL_INTERVAL_MS),
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%% Internals

schedule_tick(Delay) ->
    erlang:send_after(Delay, self(), tick).

%% Synchronous and exported: the timer calls it every tick, an operator
%% or a test can call it directly to force an immediate rescan.
-spec scan() -> ok.
scan() ->
    scan_config(corpus_repos_config:read()).

%% A missing/invalid config file means nothing to scan -- report it,
%% don't crash the gen_server over it (mirrors corpus_git_sync's own
%% posture: stay up and do nothing until the config is actually there).
scan_config({error, Reason}) ->
    logger:warning("[refresh_corpus_scheduler] config unreadable: ~p", [Reason]);
scan_config({ok, Repos}) ->
    lists:foreach(fun scan_repo/1, Repos).

%% corpus_repos_config's path is a binary (the NIF side needs it as
%% one); filelib:wildcard/1 and this module's own relative_path/2
%% (which uses list ++) both require a list, unlike filelib:is_dir/1,
%% which happens to accept either -- convert once, here, rather than
%% at every call site downstream.
scan_repo(#{id := RepoId, path := Root}) ->
    RootList = binary_to_list(Root),
    scan_root(RepoId, filelib:is_dir(RootList), RootList).

%% Not every configured repo is necessarily cloned yet (corpus_git_sync
%% hasn't reached it on its own independent tick) -- skip quietly
%% rather than erroring on a missing directory.
scan_root(_RepoId, false, _Root) ->
    ok;
scan_root(RepoId, true, Root) ->
    Files = filelib:wildcard(filename:join(Root, ?GLOB)),
    lists:foreach(fun(P) -> scan_file(RepoId, Root, P) end, Files).

scan_file(RepoId, Root, AbsPath) ->
    RelPath = relative_path(Root, AbsPath),
    case file:read_file(AbsPath) of
        {ok, Content} ->
            check_and_refresh(RepoId, RelPath, Content);
        {error, Reason} ->
            logger:warning("[refresh_corpus_scheduler] ~s: read error path=~ts ~p",
                            [RepoId, RelPath, Reason])
    end.

%% Same trailing-slash normalization maybe_seed_corpus:ingest_file/3 uses --
%% needed here too since a repo's path is config-supplied and could end
%% in "/".
relative_path(RootDir, AbsPath) ->
    Prefix = string:trim(RootDir, trailing, "/") ++ "/",
    list_to_binary(string:replace(AbsPath, Prefix, "", leading)).

check_and_refresh(RepoId, RelPath, Content) ->
    DocId = namespaced_id(RepoId, RelPath),
    Hash = diff_hash(Content),
    Detect = #{<<"corpus_id">> => RepoId, <<"source_path">> => DocId,
               <<"diff_hash">> => Hash},
    case maybe_detect_corpus_change:detect(Detect) of
        {ok, #{changed := 1}} -> refresh_changed(RepoId, DocId, Content);
        {ok, #{changed := 0}} -> ok;
        {error, Reason} ->
            logger:warning("[refresh_corpus_scheduler] ~s: detect error path=~ts ~p",
                            [RepoId, DocId, Reason])
    end.

refresh_changed(RepoId, DocId, Content) ->
    %% Best-effort record; {error, not_ingested} for a brand-new file is
    %% expected (nothing to schedule against yet) and not itself an error --
    %% refresh_file below ingests it regardless.
    _ = maybe_schedule_reembed:schedule(#{<<"corpus_id">> => RepoId,
                                           <<"source_path">> => DocId}),
    refresh_file(RepoId, DocId, Content).

refresh_file(RepoId, DocId, Content) ->
    Source = #{
        document_id => DocId, source_path => DocId,
        source_type => <<"markdown">>, raw_bytes => Content
    },
    source_refreshed(rag_store:upsert_source(Source), RepoId, DocId).

source_refreshed(ok, RepoId, DocId) ->
    embed_refreshed(maybe_embed_document:embed(#{<<"document_id">> => DocId}), RepoId, DocId);
source_refreshed({error, Reason}, RepoId, DocId) ->
    logger:warning("[refresh_corpus_scheduler] source store error path=~ts ~p", [DocId, Reason]),
    retry_next_tick(RepoId, DocId).

embed_refreshed({ok, _}, _RepoId, _DocId) ->
    ok;
embed_refreshed({error, Reason}, RepoId, DocId) ->
    logger:warning("[refresh_corpus_scheduler] embed error path=~ts ~p", [DocId, Reason]),
    retry_next_tick(RepoId, DocId).

%% detect_corpus_change already wrote the file's real hash as its
%% watermark before this refresh ran; overwrite it with a value no real
%% hash equals, so the next tick sees the file as changed and retries.
retry_next_tick(RepoId, DocId) ->
    retry_marked(rag_store:put_watermark(RepoId, DocId, ?RETRY_WATERMARK), DocId).

retry_marked(ok, _DocId) ->
    ok;
retry_marked({error, Reason}, DocId) ->
    logger:warning("[refresh_corpus_scheduler] retry watermark error path=~ts ~p", [DocId, Reason]).

namespaced_id(RepoId, RelPath) ->
    <<RepoId/binary, "/", RelPath/binary>>.

diff_hash(Content) ->
    binary:encode_hex(crypto:hash(sha256, [?INDEX_GENERATION, Content])).
