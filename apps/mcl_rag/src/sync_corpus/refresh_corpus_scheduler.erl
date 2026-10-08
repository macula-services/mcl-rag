%%% @doc Keeps the corpus current: every `?POLL_INTERVAL_MS', for every repo
%%% `corpus_repos_config:read/0' lists, follows its branch head and makes the
%%% store hold exactly that head's files (mcl-rag#24, #25).
%%%
%%% Per repo: `mcl_rag_corpus_sync_nif:sync_to_head/3' fetches the branch and
%%% checks its head out, and says which commit that is. A repo the store
%%% already serves at that head, under this index generation, is done. Else
%%% every ingestible file of the checkout is compared with its watermark:
%%%
%%%   - changed (or new): its old chunks are dropped, then it is re-ingested
%%%     and re-embedded, stamped with the head. Dropping first matters: chunk
%%%     ids are position-derived, so a file that changed shape would otherwise
%%%     keep the chunks of positions it no longer has.
%%%   - unchanged: its source record is verified at the head (one small write,
%%%     no re-embed); a hit reads its commit from there.
%%%   - gone (a watermark with no file any more): chunks, source and
%%%     watermark are dropped.
%%%
%%% Once every file is through, the repo is recorded as served at the head,
%%% which is what describe_corpus names. A file that failed keeps its retry
%%% watermark and the repo stays unserved at the head, so the next tick tries
%%% again. A repo that has left the list loses everything it ever stored.
%%%
%%% `?INDEX_GENERATION' salts every hash. Bump it when what a refresh WRITES
%%% changes shape, so every file re-ingests exactly once on the next tick and
%%% a store built by the old code catches up without anyone touching the
%%% corpus. A repo first refreshed under a new generation also has every chunk
%%% no current file leads to swept: the one-off clean-up of chunks older code
%%% left behind.
%%%
%%% `document_id'/`source_path' are `<<RepoId/binary, "/",
%%% RelPath/binary>>', not the bare relative path: two repos that both have a
%%% README.md must not overwrite each other's record. Contract-visible:
%%% `mcl-rag.get_document_verbatim' takes `"<repo-id>/<relative-path>"'.
%%%
%%% Which files are ingested, and what is stripped from them, is
%%% `corpus_boilerplate''s (mcl-rag#26).
-module(refresh_corpus_scheduler).
-behaviour(gen_server).

-export([start_link/0, scan/0, refresh_repo/2, attempt/1, relative_path/2, sanitise_utf8/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(POLL_INTERVAL_MS, 7200000).
-define(GLOB, "**/*.md").
-define(INDEX_GENERATION, <<"heads-v3:">>).
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
%% or a test can call it directly to force an immediate refresh.
-spec scan() -> ok.
scan() ->
    scan_config(corpus_repos_config:read()).

%% A missing/invalid config file means nothing to follow -- report it,
%% don't crash the gen_server over it: stay up, serve what is stored, and do
%% nothing until the list is there.
scan_config({error, Reason}) ->
    logger:warning("[refresh_corpus_scheduler] config unreadable: ~p", [Reason]);
scan_config({ok, Repos}) ->
    lists:foreach(fun follow_repo/1, Repos),
    prune_removed([Id || #{id := Id} <- Repos]).

%% ensure_dir(Path) creates Path's PARENT chain, deliberately not Path
%% itself: a fresh clone needs its own leaf directory not to exist yet.
follow_repo(#{id := Id, url := Url, branch := Branch, path := Path} = Repo) ->
    ok = filelib:ensure_dir(Path),
    case mcl_rag_corpus_sync_nif:sync_to_head(Url, Path, Branch) of
        {ok, Head, _Moved}           -> refresh_repo(Repo, Head);
        {error, {git_error, Msg}}    -> logger:warning("[refresh_corpus_scheduler] ~s: git error: ~ts", [Id, Msg])
    end.

%% @doc Make the store hold exactly the files of `Repo''s checkout, which is
%% at `Head'. Exported for the suites, whose checkouts are plain directories.
-spec refresh_repo(#{id := binary(), path := binary(), _ => _}, binary()) -> ok.
refresh_repo(#{id := RepoId, path := Root}, Head) ->
    refresh_unless_served(rag_store:get_served(RepoId), RepoId, binary_to_list(Root), Head).

refresh_unless_served({ok, #{commit := Head, generation := ?INDEX_GENERATION}}, _RepoId, _Root, Head) ->
    ok;
refresh_unless_served({error, store_opening}, _RepoId, _Root, _Head) ->
    ok;
refresh_unless_served(Served, RepoId, Root, Head) ->
    refresh_checkout(filelib:is_dir(Root), Served, RepoId, Root, Head).

refresh_checkout(false, _Served, RepoId, Root, _Head) ->
    logger:warning("[refresh_corpus_scheduler] ~s: no checkout at ~ts", [RepoId, Root]);
refresh_checkout(true, Served, RepoId, Root, Head) ->
    Files = [{relative_path(Root, P), P} || P <- filelib:wildcard(filename:join(Root, ?GLOB)),
                                          corpus_boilerplate:ingestible(relative_path(Root, P))],
    Current = [namespaced_id(RepoId, Rel) || {Rel, _} <- Files],
    Results = [scan_file(RepoId, Head, Rel, Abs) || {Rel, Abs} <- Files],
    Failed = [R || R <- Results, R =:= failed],
    Vanished = drop_vanished(RepoId, Current),
    Swept = swept(Served, RepoId, Current),
    served(Failed, Vanished, Swept, RepoId, Head).

%% Every watermark with no file behind it any more: the file left the repo,
%% or became something corpus_boilerplate does not ingest.
drop_vanished(RepoId, Current) ->
    case rag_store:watermarked_paths(RepoId) of
        {ok, Known} -> all_dropped(RepoId, Known -- Current);
        {error, Reason} ->
            logger:warning("[refresh_corpus_scheduler] ~s: watermarks unreadable ~p", [RepoId, Reason]),
            false
    end.

all_dropped(RepoId, DocIds) ->
    lists:all(fun(Result) -> Result =:= ok end, [dropped(RepoId, D) || D <- DocIds]).

dropped(RepoId, DocId) ->
    case {rag_store:forget_chunks_of_source(DocId), rag_store:forget_source(DocId),
          rag_store:forget_watermark(RepoId, DocId)} of
        {{ok, _}, ok, ok} -> ok;
        Refused ->
            logger:warning("[refresh_corpus_scheduler] ~s: could not drop path=~ts ~p", [RepoId, DocId, Refused]),
            failed
    end.

%% First refresh under this generation: also drop every chunk of the repo no
%% current file leads to (chunks older code left with no watermark).
swept({ok, #{generation := ?INDEX_GENERATION}}, _RepoId, _Current) ->
    true;
swept(_OlderOrNone, RepoId, Current) ->
    case rag_store:forget_chunks_of_repo_except(RepoId, Current) of
        {ok, N} ->
            logger:info("[refresh_corpus_scheduler] ~s: swept ~b chunks no file leads to", [RepoId, N]),
            true;
        {error, Reason} ->
            logger:warning("[refresh_corpus_scheduler] ~s: sweep failed ~p", [RepoId, Reason]),
            false
    end.

served([], true, true, RepoId, Head) ->
    case rag_store:put_served(RepoId, Head, ?INDEX_GENERATION) of
        ok -> logger:info("[refresh_corpus_scheduler] ~s: serving ~s", [RepoId, Head]);
        {error, Reason} -> logger:warning("[refresh_corpus_scheduler] ~s: served record ~p", [RepoId, Reason])
    end;
served(Failed, _Vanished, _Swept, RepoId, Head) ->
    logger:warning("[refresh_corpus_scheduler] ~s: not yet serving ~s (~b files failed), retrying next tick",
                   [RepoId, Head, length(Failed)]).

%% A repo the store holds anything of (a watermark or a served record) that
%% the list no longer names loses all of it.
prune_removed(Listed) ->
    case {rag_store:watermarked_corpora(), rag_store:served_repos()} of
        {{ok, Watermarked}, {ok, Served}} ->
            lists:foreach(fun remove_repo/1, lists:usort(Watermarked ++ maps:keys(Served)) -- Listed);
        Refused ->
            logger:warning("[refresh_corpus_scheduler] removed repos not checked: ~p", [Refused])
    end.

remove_repo(RepoId) ->
    _ = drop_vanished(RepoId, []),
    _ = rag_store:forget_chunks_of_repo_except(RepoId, []),
    ok = rag_store:forget_served(RepoId),
    logger:info("[refresh_corpus_scheduler] ~s: left the corpus, its chunks are dropped", [RepoId]).

scan_file(RepoId, Head, RelPath, AbsPath) ->
    Scan = fun() -> scan_one(RepoId, Head, RelPath, AbsPath) end,
    case attempt(Scan) of
        {ok, Result} ->
            Result;
        {crash, Class, Reason, Stack} ->
            %% The whole per-file scan is contained (issue #7).
            logger:error("[refresh_corpus_scheduler] ~s: scan crashed path=~ts ~p:~p ~p",
                         [RepoId, AbsPath, Class, Reason, Stack]),
            failed
    end.

scan_one(RepoId, Head, RelPath, AbsPath) ->
    case file:read_file(AbsPath) of
        {ok, Raw} ->
            refresh_file_contained(RepoId, Head, RelPath, sanitise_utf8(Raw));
        {error, Reason} ->
            logger:warning("[refresh_corpus_scheduler] ~s: read error path=~ts ~p",
                            [RepoId, RelPath, Reason]),
            failed
    end.

%% One bad file costs one file, not the scan (issue #3): say where, reset its
%% watermark, carry on with the rest.
refresh_file_contained(RepoId, Head, RelPath, Content) ->
    DocId = namespaced_id(RepoId, RelPath),
    Refresh = fun() -> check_and_refresh(RepoId, Head, RelPath, Content) end,
    case attempt(Refresh) of
        {ok, Result} ->
            Result;
        {crash, Class, Reason, Stack} ->
            logger:error("[refresh_corpus_scheduler] ~s: refresh crashed path=~ts ~p:~p ~p",
                         [RepoId, RelPath, Class, Reason, Stack]),
            retry_next_tick(RepoId, DocId)
    end.

%% Same trailing-slash normalization maybe_seed_corpus:ingest_file/3 uses --
%% needed here too since a repo's path is config-supplied and could end
%% in "/". characters_to_binary, not list_to_binary: corpus filenames are not
%% all Latin-1 (rt-thread's docs include CJK names) and a codepoint above 255
%% is a badarg for list_to_binary/1 (issue #7). Exported for its own test.
relative_path(RootDir, AbsPath) ->
    Prefix = string:trim(RootDir, trailing, "/") ++ "/",
    unicode:characters_to_binary(string:replace(AbsPath, Prefix, "", leading)).

check_and_refresh(RepoId, Head, RelPath, Content) ->
    DocId = namespaced_id(RepoId, RelPath),
    Hash = diff_hash(Content),
    Detect = #{<<"corpus_id">> => RepoId, <<"source_path">> => DocId,
               <<"diff_hash">> => Hash},
    case maybe_detect_corpus_change:detect(Detect) of
        {ok, #{changed := 1}} -> refresh_changed(RepoId, Head, DocId, Content);
        {ok, #{changed := 0}} -> verified(rag_store:verify_source(DocId, Head), RepoId, DocId);
        {error, Reason} ->
            logger:warning("[refresh_corpus_scheduler] ~s: detect error path=~ts ~p",
                            [RepoId, DocId, Reason]),
            failed
    end.

%% Unchanged bytes are present at the head: say so on the source record.
verified(ok, _RepoId, _DocId) ->
    ok;
verified({error, Reason}, RepoId, DocId) ->
    logger:warning("[refresh_corpus_scheduler] ~s: verify error path=~ts ~p", [RepoId, DocId, Reason]),
    retry_next_tick(RepoId, DocId).

refresh_changed(RepoId, Head, DocId, Content) ->
    %% Best-effort record; {error, not_ingested} for a brand-new file is
    %% expected (nothing to schedule against yet) and not itself an error.
    _ = maybe_schedule_reembed:schedule(#{<<"corpus_id">> => RepoId,
                                           <<"source_path">> => DocId}),
    cleared(rag_store:forget_chunks_of_source(DocId), RepoId, Head, DocId, Content).

%% The file's old chunks go first, then it is ingested afresh.
cleared({ok, _}, RepoId, Head, DocId, Content) ->
    refresh_file(RepoId, Head, DocId, Content);
cleared({error, Reason}, RepoId, _Head, DocId, _Content) ->
    logger:warning("[refresh_corpus_scheduler] ~s: old chunks not dropped path=~ts ~p", [RepoId, DocId, Reason]),
    retry_next_tick(RepoId, DocId).

%% Recorded as corpus content: this repo, at the head it was read at.
refresh_file(RepoId, Head, DocId, Content) ->
    Source = #{
        document_id => DocId, source_path => DocId,
        source_type => <<"markdown">>, raw_bytes => Content,
        repo_id => RepoId, commit => Head
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

%% Either way the file failed this tick, and its repo is not served at the
%% head until it succeeds.
retry_marked(ok, _DocId) ->
    failed;
retry_marked({error, Reason}, DocId) ->
    logger:warning("[refresh_corpus_scheduler] retry watermark error path=~ts ~p", [DocId, Reason]),
    failed.

%% Wraps one per-file step so an exception becomes a value instead of a
%% dead scan (issue #3). Exported for its own test.
attempt(Fun) when is_function(Fun, 0) ->
    try {ok, Fun()}
    catch Class:Reason:Stack -> {crash, Class, Reason, Stack}
    end.

%% Lossy UTF-8: valid text is kept, each invalid or truncated byte becomes
%% U+FFFD. rt-thread's docs are GBK/Latin-1 in places, and the JSON encoder on
%% the way to the embedder raises on those bytes, so the file used to fail its
%% embed every tick (issue #10). Exported for its own test.
sanitise_utf8(Bin) when is_binary(Bin) ->
    case unicode:characters_to_binary(Bin, utf8, utf8) of
        Converted when is_binary(Converted) ->
            Converted;
        {error, Good, Rest} ->
            Tail = sanitise_tail(Rest),
            <<Good/binary, Tail/binary>>;
        {incomplete, Good, Rest} ->
            Tail = sanitise_tail(Rest),
            <<Good/binary, Tail/binary>>
    end.

sanitise_tail(<<_Bad, Rest/binary>>) ->
    Replacement = unicode:characters_to_binary([16#FFFD]),
    Tail = sanitise_utf8(Rest),
    <<Replacement/binary, Tail/binary>>;
sanitise_tail(<<>>) ->
    <<>>.

namespaced_id(RepoId, RelPath) ->
    <<RepoId/binary, "/", RelPath/binary>>.

diff_hash(Content) ->
    binary:encode_hex(crypto:hash(sha256, [?INDEX_GENERATION, Content])).
