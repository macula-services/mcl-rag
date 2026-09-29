%%% @doc Smoke tests for mcl-rag.
-module(mcl_rag_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([service_info/1, capabilities_advertised/1, identity_spec_shape/1, mesh_rpc_dispatch_unknown/1,
         corpus_repos_config_reads_multiple_repos/1, corpus_git_sync_follows_the_listed_commit/1]).

all() ->
    [service_info, capabilities_advertised, identity_spec_shape, mesh_rpc_dispatch_unknown,
     corpus_repos_config_reads_multiple_repos, corpus_git_sync_follows_the_listed_commit].

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
    ?assertMatch(<<_:40/binary>>, maps:get(commit, RepoB)),

    ok = rag_test_helpers:restore_env(corpus_repos_config, PrevReposConfig),
    ok = rag_test_helpers:restore_env(data_dir, PrevDataDir).

%% End-to-end proof that the embedded Rust NIF loads and works inside a real
%% running mcl_rag application (the crate's own `cargo test' excludes the
%% rustler wrapper), and that corpus_git_sync ingests exactly the listed
%% commit: it clones and checks it out, stays on it when the branch moves, and
%% moves only when the list names a new commit. Fixture repos are built with
%% the real `git' CLI here -- the property proved is that the RELEASE's sync
%% needs no `git' binary at runtime.
corpus_git_sync_follows_the_listed_commit(Config) ->
    TmpDir = ?config(priv_dir, Config),
    RemoteDir = filename:join(TmpDir, "remote.git"),
    OriginDir = filename:join(TmpDir, "origin-workdir"),
    DataDir = filename:join(TmpDir, "data"),
    ConfigPath = filename:join(TmpDir, "corpus-repos.json"),
    RepoId = <<"test-repo">>,
    LocalDir = filename:join([DataDir, "corpus", "test-repo"]),

    ok = git_init_bare(RemoteDir),
    ok = git_clone(RemoteDir, OriginDir),
    ok = git_commit_and_push(OriginDir, "corpus.md", "# v1\n", "initial"),
    Branch = git_out(OriginDir, "rev-parse --abbrev-ref HEAD"),
    V1 = git_out(OriginDir, "rev-parse HEAD"),
    Pin = fun(Commit) ->
        ok = rag_test_helpers:write_repos_config(ConfigPath, [#{id => RepoId, url => list_to_binary(RemoteDir),
                                                                 branch => Branch, commit => Commit}])
    end,
    ok = Pin(V1),
    PrevReposConfig = application:get_env(mcl_rag, corpus_repos_config),
    ok = application:set_env(mcl_rag, corpus_repos_config, ConfigPath),
    PrevDataDir = application:get_env(mcl_rag, data_dir),
    ok = application:set_env(mcl_rag, data_dir, DataDir),

    %% Local path doesn't exist yet -- clones itself, at the listed commit.
    ?assertEqual(#{RepoId => {ok, {moved, <<>>, V1}}}, corpus_git_sync:sync_now()),
    ?assertEqual({ok, <<"# v1\n">>}, file:read_file(filename:join(LocalDir, "corpus.md"))),
    ?assertEqual(#{RepoId => {ok, up_to_date}}, corpus_git_sync:sync_now()),

    %% A push to the branch is not ingested.
    ok = git_commit_and_push(OriginDir, "corpus.md", "# v2\n", "update"),
    V2 = git_out(OriginDir, "rev-parse HEAD"),
    ?assertEqual(#{RepoId => {ok, up_to_date}}, corpus_git_sync:sync_now()),
    ?assertEqual({ok, <<"# v1\n">>}, file:read_file(filename:join(LocalDir, "corpus.md"))),

    %% Advancing the list moves it.
    ok = Pin(V2),
    ?assertEqual(#{RepoId => {ok, {moved, V1, V2}}}, corpus_git_sync:sync_now()),
    ?assertEqual({ok, <<"# v2\n">>}, file:read_file(filename:join(LocalDir, "corpus.md"))),

    ok = rag_test_helpers:restore_env(corpus_repos_config, PrevReposConfig),
    ok = rag_test_helpers:restore_env(data_dir, PrevDataDir).

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
