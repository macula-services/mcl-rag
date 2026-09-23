%%% @doc Integration tests for the ingest -> embed -> search -> prune
%%% pipeline, and the sources query desks. Direct writes to `rag_store'
%%% (barrel, record mode) — no evoq, no aggregate, no projections.
%%%
%%% Boots the real `mcl_rag' application against real `barrel' storage
%%% and a real `mcl_embed'-equivalent call (barrel's own Ollama
%%% embedder) with the HTTP/health ports overridden to avoid colliding
%%% with any already-running mcl-rag instance on this box.
-module(embed_corpus_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([ingest_embed_search_prune_round_trip/1, sources_query_round_trip/1,
         embed_without_ingest_errors/1, seed_corpus_creates_verbatim_source/1,
         get_document_verbatim_round_trip/1, retire_document_round_trip/1,
         sources_paging_walks_the_whole_store/1, retire_document_takes_orphan_chunks/1,
         refresh_scheduler_detects_and_refreshes_change/1,
         refresh_scheduler_namespaces_by_repo_to_avoid_collisions/1]).

all() ->
    [ingest_embed_search_prune_round_trip, sources_query_round_trip,
     embed_without_ingest_errors, seed_corpus_creates_verbatim_source,
     get_document_verbatim_round_trip, retire_document_round_trip,
     sources_paging_walks_the_whole_store, retire_document_takes_orphan_chunks,
     refresh_scheduler_detects_and_refreshes_change,
     refresh_scheduler_namespaces_by_repo_to_avoid_collisions].

init_per_suite(Config) ->
    ok = rag_test_helpers:start_mcl_rag(),
    Config.

end_per_suite(_Config) ->
    rag_test_helpers:stop_mcl_rag().

ingest_embed_search_prune_round_trip(_Config) ->
    DocId = fresh_id(),
    %% Unique per run: chunk_id is content/source_path-derived, not
    %% document-id-derived, so this is what distinguishes "our" hit.
    SourcePath = <<"quokka-", DocId/binary, ".md">>,
    Content = <<"# The Quokka Habitat\n\nQuokkas are marsupials found "
                "almost exclusively on Rottnest Island off Western "
                "Australia's coast.\n">>,
    {ok, _} = ingest(DocId, SourcePath, Content),
    {ok, #{chunks := N}} = embed(DocId),
    ?assert(N > 0),

    %% Real embedding call (rag_embedder -> Ollama in test config, made
    %% in maybe_embed_document's own process), real search -- the
    %% pipeline that has been silently dead twice: first when nothing
    %% embedded at all, then (live, 2026-09-02) when embed_document
    %% wrote chunks without a vector. barrel indexes a client-supplied
    %% vector synchronously, so the write is searchable the instant
    %% put_chunk_with_vector returns, no polling needed. The hit must
    %% also carry the chunk's content: barrel keeps no text for vectors
    %% it did not embed itself, so rag_store reads it back from the doc.
    {ok, Hits} = rag_store:search_text(<<"Where do quokkas live?">>, 5),
    ?assert(hit_from_source(Hits, SourcePath)),
    ?assertMatch([#{content := <<_, _/binary>>} | _],
                 [H || #{source_path := SP} = H <- Hits, SP =:= SourcePath]),

    {ok, _} = prune(DocId),
    {ok, GoneHits} = rag_store:search_text(<<"Where do quokkas live?">>, 5),
    ?assertNot(hit_from_source(GoneHits, SourcePath)).

sources_query_round_trip(_Config) ->
    DocId = fresh_id(),
    {ok, _} = ingest(DocId, <<"source-listing-test.md">>, <<"# Hello\n\nWorld.\n">>),

    {ok, Source} = get_source_by_id:handle(DocId),
    ?assertEqual(DocId, maps:get(document_id, Source)),
    ?assertEqual(<<"source-listing-test.md">>, maps:get(source_path, Source)),

    {ok, Page} = list_sources_page:handle(#{}),
    ?assert(lists:any(fun(S) -> maps:get(document_id, S) =:= DocId end, Page)).

embed_without_ingest_errors(_Config) ->
    DocId = fresh_id(),
    Result = maybe_embed_document:embed(#{<<"document_id">> => DocId}),
    ?assertEqual({error, not_ingested}, Result).

%% seed_corpus is the bulk directory-walk path (distinct from ingest/1's
%% per-document one above) — this asserts it now also leaves a verbatim
%% source record per file, not chunks-only, and that re-seeding upserts
%% rather than erroring or duplicating.
seed_corpus_creates_verbatim_source(Config) ->
    SeedId = fresh_id(),
    RelPath = <<"quokka-seed-", SeedId/binary, ".md">>,
    TmpDir = ?config(priv_dir, Config),
    Content = <<"# Quokka Seeding\n\nSeeded straight from a directory "
                "walk, not a per-document upload.\n">>,
    ok = file:write_file(filename:join(TmpDir, RelPath), Content),

    {ok, _Stats} = maybe_seed_corpus:seed(seed_cmd(SeedId, TmpDir)),
    ?assertEqual({ok, #{source_path => RelPath, raw_bytes => Content}},
                 rag_store:get_source_content(RelPath)),

    %% Re-seeding the same file (content unchanged) upserts, not errors.
    {ok, _Stats2} = maybe_seed_corpus:seed(seed_cmd(SeedId, TmpDir)),
    ?assertEqual({ok, #{source_path => RelPath, raw_bytes => Content}},
                 rag_store:get_source_content(RelPath)).

seed_cmd(SeedId, RootDir) ->
    #{<<"seed_id">> => SeedId, <<"root_dir">> => list_to_binary(RootDir),
      <<"glob">> => <<"*.md">>}.

%% get_document_verbatim composes find_source_by_path + get_source_content
%% -- this exercises that composition against a per-document-ingested
%% source (seed_corpus_creates_verbatim_source above already covers the
%% bulk-seeded path into the same underlying storage).
get_document_verbatim_round_trip(_Config) ->
    DocId = fresh_id(),
    SourcePath = <<"verbatim-fetch-", DocId/binary, ".md">>,
    Content = <<"# Verbatim\n\nExact bytes, not a semantic approximation.\n">>,
    {ok, _} = ingest(DocId, SourcePath, Content),

    %% source_path is {text, _}-tagged for the wire; raw_bytes deliberately not.
    ?assertEqual({ok, #{source_path => {text, SourcePath}, raw_bytes => Content}},
                 get_document_verbatim:handle(SourcePath)),
    ?assertEqual({error, not_found},
                 get_document_verbatim:handle(<<"no-such-path.md">>)).

%% Chunks can outlive their source record -- the earliest seed_corpus
%% wrote chunks with no source at all -- and prune_chunks resolves a
%% document THROUGH its source record, so those chunks could not be
%% removed by any capability. Live (2026-09-02): 33 documents deleted
%% from the corpus months earlier were still answering searches.
retire_document_takes_orphan_chunks(_Config) ->
    DocId = fresh_id(),
    SourcePath = <<"bilby-", DocId/binary, ".md">>,
    Content = <<"# The Bilby\n\nBilbies are burrowing bandicoots with long "
                "ears, native to the arid interior of Australia, and they "
                "dig deep spiral burrows to escape the heat.\n">>,
    {ok, _} = ingest(DocId, SourcePath, Content),
    {ok, #{chunks := N}} = embed(DocId),
    ?assert(N > 0),

    %% Drop the source record only: exactly the shape the old seed left.
    ok = rag_store:forget_source(DocId),
    ?assertEqual({error, not_ingested},
                 maybe_prune_chunks:prune(#{<<"document_id">> => DocId})),
    {ok, Orphans} = rag_store:list_chunks_by_source(SourcePath, 100),
    ?assertNotEqual([], Orphans),

    %% The chunks are keyed by source_path, which is what a caller has.
    ?assertEqual({ok, #{document_id => SourcePath, pruned => length(Orphans)}},
                 maybe_retire_document:retire(#{<<"document_id">> => SourcePath})),
    ?assertEqual({ok, []}, rag_store:list_chunks_by_source(SourcePath, 100)),
    {ok, Hits} = rag_store:search_text(<<"which animal digs spiral burrows">>, 5),
    ?assertNot(hit_from_source(Hits, SourcePath)),
    ?assertEqual({error, not_ingested},
                 maybe_retire_document:retire(#{<<"document_id">> => SourcePath})).

%% Paging has to actually page: barrel's find/3 takes no `offset', and
%% passing one returns an EMPTY result rather than being ignored, so
%% every page after the first came back empty and anything walking the
%% sources saw only page one and believed it had seen everything (live,
%% 2026-09-02). Asserts the walk both COVERS the ingested documents and
%% does not repeat one, which a broken offset fails in either direction.
sources_paging_walks_the_whole_store(_Config) ->
    Run = fresh_id(),
    Ids = [<<"page-", Run/binary, "-", (integer_to_binary(N))/binary>> || N <- lists:seq(1, 7)],
    [{ok, _} = ingest(Id, <<Id/binary, ".md">>, <<"# Page\n\nOne small page fixture.\n">>)
     || Id <- Ids],

    Walked = walk_sources(0, 2, []),
    Ours = [Id || Id <- Walked, lists:member(Id, Ids)],
    ?assertEqual(lists:sort(Ids), lists:sort(Ours)),
    ?assertEqual(length(Walked), length(lists:usort(Walked))).

%% Pages until a short page, exactly as a mesh caller sweeping the store
%% does -- a deliberately tiny page size so the walk crosses several.
walk_sources(Offset, Limit, Acc) ->
    {ok, Page} = list_sources_page:handle(#{<<"offset">> => Offset, <<"limit">> => Limit}),
    Ids = Acc ++ [maps:get(document_id, S) || S <- Page],
    walk_more(length(Page) < Limit, Offset + Limit, Limit, Ids).

walk_more(true, _Offset, _Limit, Acc)  -> Acc;
walk_more(false, Offset, Limit, Acc)   -> walk_sources(Offset, Limit, Acc).

%% retire_document is prune_chunks plus the source record: afterwards the
%% document is unknown everywhere, not merely unsearchable -- and a second
%% retire of the same id is the same not_ingested any unknown id gets.
retire_document_round_trip(_Config) ->
    DocId = fresh_id(),
    SourcePath = <<"numbat-", DocId/binary, ".md">>,
    %% Long enough for markdown_chunker not to skip it as a stub section.
    Content = <<"# The Numbat\n\nNumbats are small marsupials that eat "
                "termites almost exclusively, up to twenty thousand a day, "
                "and live in the eucalypt woodlands of Western Australia.\n">>,
    {ok, _} = ingest(DocId, SourcePath, Content),
    {ok, #{chunks := N}} = embed(DocId),
    ?assert(N > 0),

    ?assertEqual({ok, #{document_id => DocId, pruned => N}},
                 maybe_retire_document:retire(#{<<"document_id">> => DocId})),
    ?assertEqual({error, not_found}, rag_store:get_source(DocId)),
    ?assertEqual({error, not_found}, rag_store:find_source_by_path(SourcePath)),
    ?assertEqual({error, not_found}, get_document_verbatim:handle(SourcePath)),
    {ok, Hits} = rag_store:search_text(<<"What do numbats eat?">>, 5),
    ?assertNot(hit_from_source(Hits, SourcePath)),
    ?assertEqual({error, not_ingested},
                 maybe_retire_document:retire(#{<<"document_id">> => DocId})).

%% refresh_corpus_scheduler:scan/0 is the internal half of the freshness
%% loop (the external half -- keeping each checkout in sync with git --
%% is corpus_git_sync's own job, not exercised here). Points
%% corpus_repos_config at a fixture repo list naming one fixture dir
%% instead of a real cloned checkout -- scan/0 only reads files off
%% disk, it doesn't care whether git put them there. `path' is never a
%% JSON field, only ever derived (data_dir/corpus/id, see
%% corpus_repos_config:clone_path/1), so the fixture data_dir has to
%% be overridden too, and RepoDir computed the exact same way.
refresh_scheduler_detects_and_refreshes_change(Config) ->
    DocId = fresh_id(),
    RepoId = <<"refresh-repo-", DocId/binary>>,
    RelPath = <<"corpus.md">>,
    TmpDir = ?config(priv_dir, Config),
    DataDir = filename:join(TmpDir, <<"refresh-data-", DocId/binary>>),
    RepoDir = filename:join([DataDir, "corpus", RepoId]),
    ConfigPath = filename:join(TmpDir, <<"refresh-config-", DocId/binary, ".json">>),
    NamespacedId = <<RepoId/binary, "/", RelPath/binary>>,
    ok = filelib:ensure_dir(filename:join(RepoDir, ".")),
    ok = rag_test_helpers:write_repos_config(ConfigPath, [#{id => RepoId, url => <<"unused">>}]),
    PrevReposConfig = application:get_env(mcl_rag, corpus_repos_config),
    ok = application:set_env(mcl_rag, corpus_repos_config, ConfigPath),
    PrevDataDir = application:get_env(mcl_rag, data_dir),
    ok = application:set_env(mcl_rag, data_dir, DataDir),

    AbsPath = filename:join(RepoDir, RelPath),
    Original = <<"# Before\n\nThe okapi, a forest giraffe, lives only in the "
                 "Ituri rainforest of Congo.\n">>,
    ok = file:write_file(AbsPath, Original),
    ok = refresh_corpus_scheduler:scan(),
    ?assertEqual({ok, #{source_path => NamespacedId, raw_bytes => Original}},
                 rag_store:get_source_content(NamespacedId)),
    %% Verbatim is not enough: the scheduler's refresh must also make the
    %% file a semantic hit (live, 2026-09-02: every git-synced file was
    %% fetchable and unsearchable, because this path wrote no vectors).
    {ok, Hits} = rag_store:search_text(<<"Where does the okapi live?">>, 5),
    ?assert(hit_from_source(Hits, NamespacedId)),

    %% Unchanged content -- a second scan is a no-op, same content still there.
    ok = refresh_corpus_scheduler:scan(),
    ?assertEqual({ok, #{source_path => NamespacedId, raw_bytes => Original}},
                 rag_store:get_source_content(NamespacedId)),

    %% Changed content -- the next scan picks it up.
    Updated = <<"# After\n\nUpdated content, different bytes.\n">>,
    ok = file:write_file(AbsPath, Updated),
    ok = refresh_corpus_scheduler:scan(),
    ?assertEqual({ok, #{source_path => NamespacedId, raw_bytes => Updated}},
                 rag_store:get_source_content(NamespacedId)),

    ok = rag_test_helpers:restore_env(corpus_repos_config, PrevReposConfig),
    ok = rag_test_helpers:restore_env(data_dir, PrevDataDir).

%% The real reason document ids get repo-namespaced: two configured
%% repos that both happen to have a same-named file must not collide
%% in rag_store, which keys purely on document_id with no repo scoping
%% of its own.
refresh_scheduler_namespaces_by_repo_to_avoid_collisions(Config) ->
    DocId = fresh_id(),
    RepoA = <<"collide-a-", DocId/binary>>,
    RepoB = <<"collide-b-", DocId/binary>>,
    RelPath = <<"README.md">>,
    TmpDir = ?config(priv_dir, Config),
    DataDir = filename:join(TmpDir, <<"collide-data-", DocId/binary>>),
    DirA = filename:join([DataDir, "corpus", RepoA]),
    DirB = filename:join([DataDir, "corpus", RepoB]),
    ConfigPath = filename:join(TmpDir, <<"collide-config-", DocId/binary, ".json">>),
    ok = filelib:ensure_dir(filename:join(DirA, ".")),
    ok = filelib:ensure_dir(filename:join(DirB, ".")),
    ok = rag_test_helpers:write_repos_config(ConfigPath, [
        #{id => RepoA, url => <<"unused">>},
        #{id => RepoB, url => <<"unused">>}
    ]),
    PrevReposConfig = application:get_env(mcl_rag, corpus_repos_config),
    ok = application:set_env(mcl_rag, corpus_repos_config, ConfigPath),
    PrevDataDir = application:get_env(mcl_rag, data_dir),
    ok = application:set_env(mcl_rag, data_dir, DataDir),

    ok = file:write_file(filename:join(DirA, RelPath), <<"# From A\n">>),
    ok = file:write_file(filename:join(DirB, RelPath), <<"# From B\n">>),
    ok = refresh_corpus_scheduler:scan(),

    IdA = <<RepoA/binary, "/", RelPath/binary>>,
    IdB = <<RepoB/binary, "/", RelPath/binary>>,
    ?assertEqual({ok, #{source_path => IdA, raw_bytes => <<"# From A\n">>}},
                 rag_store:get_source_content(IdA)),
    ?assertEqual({ok, #{source_path => IdB, raw_bytes => <<"# From B\n">>}},
                 rag_store:get_source_content(IdB)),

    ok = rag_test_helpers:restore_env(corpus_repos_config, PrevReposConfig),
    ok = rag_test_helpers:restore_env(data_dir, PrevDataDir).

%%% Internals

%% Binary-keyed, matching what `maybe_*''s `from_map/1' expects and what
%% the real HTTP layer actually sends (JSON-decoded params) — these
%% helpers exercise the same shape as a real caller, not a convenience one.
ingest(DocId, SourcePath, RawBytes) ->
    maybe_ingest_document:ingest(#{
        <<"document_id">> => DocId, <<"source_path">> => SourcePath,
        <<"source_type">> => <<"text/markdown">>, <<"raw_bytes">> => RawBytes
    }).

embed(DocId) ->
    maybe_embed_document:embed(#{<<"document_id">> => DocId}).

prune(DocId) ->
    maybe_prune_chunks:prune(#{<<"document_id">> => DocId}).

%% chunk_id is content/source_path-derived (markdown_chunker), not
%% document-id-derived, so source_path is what identifies "our" hit among
%% whatever else this store already holds.
hit_from_source(Hits, SourcePath) ->
    lists:any(fun(#{source_path := SP}) -> SP =:= SourcePath end, Hits).

fresh_id() ->
    integer_to_binary(erlang:unique_integer([positive, monotonic])).
