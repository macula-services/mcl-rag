%%% @doc Smoke tests for mcl-rag.
-module(mcl_rag_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([service_info/1, capabilities_advertised/1, identity_spec_shape/1, mesh_rpc_dispatch_unknown/1,
         corpus_repos_config_reads_multiple_repos/1, the_corpus_follows_the_branch_head/1]).

all() ->
    [service_info, capabilities_advertised, identity_spec_shape, mesh_rpc_dispatch_unknown,
     corpus_repos_config_reads_multiple_repos, the_corpus_follows_the_branch_head].

init_per_suite(Config) ->
    ok = rag_test_helpers:start_mcl_rag(),
    Config.

end_per_suite(_Config) ->
    rag_test_helpers:stop_mcl_rag().

service_info(_Config) ->
    Info = mcl_rag_service:info(),
    ?assertEqual(<<"mcl-rag">>, maps:get(name, Info)),
    ?assert(is_binary(maps:get(version, Info))).

capabilities_advertised(_Config) ->
    Caps = mcl_rag_service:capabilities(),
    ?assert(length(Caps) >= 10),
    Names = [maps:get(name, C) || C <- Caps],
    %% Bare names: mcl_om registers them under the org, as mcl-rag/<name>.
    ?assert(lists:member(<<"answer_query">>, Names)),
    ?assert(lists:member(<<"ingest_document">>, Names)).

identity_spec_shape(_Config) ->
    Spec = mcl_rag_service:identity_spec(),
    ?assertEqual(<<"mcl-rag">>, maps:get(scope, Spec)),
    ?assert(is_list(maps:get(actions, Spec))),
    ?assert(is_integer(maps:get(ttl_days, Spec))).

mesh_rpc_dispatch_unknown(_Config) ->
    ?assertMatch({error, {unknown_method, _}},
                 mcl_rag_mesh_rpc:dispatch(<<"mcl-rag.no_such_method">>, #{})).

%% Pure unit test of the shared config module -- no git, no NIF.
corpus_repos_config_reads_multiple_repos(Config) ->
    TmpDir = ?config(priv_dir, Config),
    ConfigPath = filename:join(TmpDir, "multi-repos.json"),
    DataDir = filename:join(TmpDir, "multi-data"),
    ok = rag_test_helpers:write_repos_config(ConfigPath, [
        #{id => <<"repo-a">>, url => <<"https://example.com/a.git">>, branch => <<"main">>},
        #{id => <<"repo-b">>, url => <<"https://example.com/b.git">>}
    ]),
    PrevReposConfig = application:get_env(mcl_rag, corpus_repos_config),
    ok = application:set_env(mcl_rag, corpus_repos_config, ConfigPath),
    PrevDataDir = application:get_env(mcl_rag, data_dir),
    ok = application:set_env(mcl_rag, data_dir, DataDir),

    {ok, [RepoA, RepoB]} = corpus_repos_config:read(),
    ?assertEqual(<<"repo-a">>, maps:get(id, RepoA)),
    ?assertEqual(<<"https://example.com/a.git">>, maps:get(url, RepoA)),
    ?assertEqual(<<"main">>, maps:get(branch, RepoA)),
    ?assertEqual(iolist_to_binary(filename:join([DataDir, "corpus", "repo-a"])), maps:get(path, RepoA)),
    ?assertEqual(<<"repo-b">>, maps:get(id, RepoB)),
    ?assertEqual(<<"main">>, maps:get(branch, RepoB)),
    ?assertNot(maps:is_key(commit, RepoB)),

    ok = rag_test_helpers:restore_env(corpus_repos_config, PrevReposConfig),
    ok = rag_test_helpers:restore_env(data_dir, PrevDataDir).

%% End-to-end, through the real NIF inside the running application (the
%% crate's own `cargo test' excludes the rustler wrapper): the corpus follows
%% its branch head (mcl-rag#24) and holds exactly that head's files (#25).
%% A push is ingested on the next refresh, with that push's commit; a file the
%% push removed is dropped with its chunks; an unchanged file names the new
%% head without being re-embedded; a repo that leaves the list loses all of
%% it. Fixture repos are built with the real `git' CLI; the release's sync
%% needs no `git' binary.
the_corpus_follows_the_branch_head(Config) ->
    TmpDir = ?config(priv_dir, Config),
    RemoteDir = filename:join(TmpDir, "remote.git"),
    OriginDir = filename:join(TmpDir, "origin-workdir"),
    DataDir = filename:join(TmpDir, "data"),
    ConfigPath = filename:join(TmpDir, "corpus-repos.json"),
    RepoId = <<"heads-repo">>,
    Kept = <<RepoId/binary, "/kept.md">>,
    Moved = <<RepoId/binary, "/moved.md">>,
    Gone = <<RepoId/binary, "/gone.md">>,

    ok = git_init_bare(RemoteDir),
    ok = git_clone(RemoteDir, OriginDir),
    ok = git_commit_and_push(OriginDir, "kept.md", "# Kept\n\nThe pangolin is covered in keratin scales. It is a fixture sentence long enough that the chunker keeps it, past its eighty-byte floor.\n", "kept"),
    ok = git_commit_and_push(OriginDir, "moved.md", "# Before\n\nThe aye-aye taps on wood to find grubs. It is a fixture sentence long enough that the chunker keeps it, past its eighty-byte floor.\n", "moved"),
    ok = git_commit_and_push(OriginDir, "gone.md", "# Gone\n\nThe axolotl regrows lost limbs. It is a fixture sentence long enough that the chunker keeps it, past its eighty-byte floor.\n", "gone"),
    Branch = git_out(OriginDir, "rev-parse --abbrev-ref HEAD"),
    V1 = git_out(OriginDir, "rev-parse HEAD"),
    ok = rag_test_helpers:write_repos_config(ConfigPath, [#{id => RepoId, url => list_to_binary(RemoteDir),
                                                             branch => Branch}]),
    PrevReposConfig = application:get_env(mcl_rag, corpus_repos_config),
    ok = application:set_env(mcl_rag, corpus_repos_config, ConfigPath),
    PrevDataDir = application:get_env(mcl_rag, data_dir),
    ok = application:set_env(mcl_rag, data_dir, DataDir),

    %% First refresh: cloned at the head, every file ingested at it, served.
    ok = refresh_corpus_scheduler:scan(),
    ?assertMatch({ok, #{commit := V1}}, rag_store:get_served(RepoId)),
    [?assertMatch({ok, #{provenance := #{commit := V1}}}, rag_store:get_source_content(Id))
     || Id <- [Kept, Moved, Gone]],
    ?assertEqual(V1, hit_commit(<<"What is a pangolin covered in?">>, Kept)),

    %% A push that changes one file and removes another.
    ok = git_commit_and_push(OriginDir, "moved.md", "# After\n\nThe aye-aye is a nocturnal lemur of Madagascar. It is a fixture sentence long enough that the chunker keeps it, past its eighty-byte floor.\n",
                             "change"),
    ok = git_ok(io_lib:format("git -C ~s rm -q gone.md && git -C ~s -c user.email=t@t -c user.name=t commit -q -m rm "
                              "&& git -C ~s push -q origin HEAD", [OriginDir, OriginDir, OriginDir])),
    V2 = git_out(OriginDir, "rev-parse HEAD"),
    ok = refresh_corpus_scheduler:scan(),
    ?assertMatch({ok, #{commit := V2}}, rag_store:get_served(RepoId)),
    %% The changed file: its new text, at the push's commit, and only its new chunks.
    ?assertMatch({ok, #{raw_bytes := <<"# After", _/binary>>, provenance := #{commit := V2}}},
                 rag_store:get_source_content(Moved)),
    {ok, MovedChunks} = rag_store:list_chunks_by_source(Moved, 100),
    ?assertEqual([], [C || #{content := C} <- MovedChunks, binary:match(C, <<"grubs">>) =/= nomatch]),
    ?assertEqual(V2, hit_commit(<<"Where does the aye-aye live?">>, Moved)),
    %% The removed file: no source, no chunks, no watermark.
    ?assertEqual({error, not_found}, rag_store:get_source(Gone)),
    ?assertEqual({ok, []}, rag_store:list_chunks_by_source(Gone, 100)),
    ?assertEqual({error, not_found}, rag_store:get_watermark(RepoId, Gone)),
    %% The unchanged file names the new head, without a re-embed.
    ?assertEqual(V2, hit_commit(<<"What is a pangolin covered in?">>, Kept)),

    %% A refresh at an unmoved head is a no-op.
    ok = refresh_corpus_scheduler:scan(),
    ?assertMatch({ok, #{commit := V2}}, rag_store:get_served(RepoId)),

    %% The repo leaves the list: everything it stored goes.
    ok = rag_test_helpers:write_repos_config(ConfigPath, []),
    ok = refresh_corpus_scheduler:scan(),
    ?assertEqual({error, not_found}, rag_store:get_served(RepoId)),
    [?assertEqual({error, not_found}, rag_store:get_source(Id)) || Id <- [Kept, Moved]],
    ?assertEqual({ok, []}, rag_store:list_chunks_by_source(Kept, 100)),
    ?assertEqual({ok, []}, rag_store:watermarked_paths(RepoId)),

    ok = rag_test_helpers:restore_env(corpus_repos_config, PrevReposConfig),
    ok = rag_test_helpers:restore_env(data_dir, PrevDataDir).

%% The commit a search hit from `SourcePath' names. The suites' embedder is a
%% hash stub with no semantics, so the search lands on the file by its own
%% chunk's vector: what is checked is the hit's provenance, not ranking.
hit_commit(_Query, SourcePath) ->
    {ok, [#{content := Content} | _]} = rag_store:list_chunks_by_source(SourcePath, 1),
    {ok, Vector} = rag_embedder:embed(passage, Content),
    {ok, Hits} = rag_store:search_vector(Vector, 10),
    [#{provenance := #{commit := Commit}} | _] = [H || #{source_path := P} = H <- Hits, P =:= SourcePath],
    Commit.

%%% git fixture helpers -- shell out to the real git CLI, test-only.

git_init_bare(Dir) ->
    git_ok(io_lib:format("git init --bare -q ~s", [Dir])).

git_clone(From, To) ->
    git_ok(io_lib:format("git clone -q ~s ~s", [From, To])).

git_commit_and_push(Dir, FileName, Content, Message) ->
    ok = file:write_file(filename:join(Dir, FileName), Content),
    git_ok(io_lib:format(
        "git -C ~s add ~s && "
        "git -C ~s -c user.email=t@t -c user.name=t commit -q -m ~s && "
        "git -C ~s push -q origin HEAD",
        [Dir, FileName, Dir, Message, Dir]
    )).

git_ok(Cmd) ->
    Full = lists:flatten(Cmd),
    Output = os:cmd(Full ++ "; echo EXIT:$?"),
    check_exit(lists:suffix("EXIT:0\n", Output), Full, Output).

%% A git command's trimmed output, as a binary (a sha, a branch name).
git_out(Dir, Args) ->
    list_to_binary(string:trim(os:cmd(lists:flatten(io_lib:format("git -C ~s ~s", [Dir, Args]))))).

check_exit(true, _Full, _Output)  -> ok;
check_exit(false, Full, Output) -> error({git_command_failed, Full, Output}).
