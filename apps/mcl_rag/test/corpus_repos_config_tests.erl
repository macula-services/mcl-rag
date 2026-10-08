%% @doc The corpus list names what to follow, never a commit (mcl-rag#24).
%%
%% Each entry is a repo and the branch its head is ingested from. Knowledge
%% evolves, so nothing is pinned: a list that still names a `commit' is refused
%% whole, naming the entry, rather than read as if the pin meant something.
-module(corpus_repos_config_tests).

-include_lib("eunit/include/eunit.hrl").

an_entry_reads_back_with_its_branch_test() ->
    with_list([entry(<<"a">>)], fun() ->
        ?assertMatch({ok, [#{id := <<"a">>, branch := <<"main">>, url := <<"https://github.com/x/a.git">>}]},
                     corpus_repos_config:read()),
        {ok, [Repo]} = corpus_repos_config:read(),
        ?assertNot(maps:is_key(commit, Repo))
    end).

an_entry_that_still_names_a_commit_refuses_the_list_test() ->
    Pinned = (entry(<<"b">>))#{<<"commit">> => <<"7fd1a60b01f91b314f59955a4e4d4e80d8edf11d">>},
    with_list([entry(<<"a">>), Pinned], fun() ->
        ?assertEqual({error, {unknown_key, <<"b">>, <<"commit">>}}, corpus_repos_config:read())
    end).

an_entry_without_a_branch_refuses_the_list_test() ->
    with_list([maps:remove(<<"branch">>, entry(<<"a">>))], fun() ->
        ?assertEqual({error, {missing_branch, <<"a">>}}, corpus_repos_config:read())
    end).

%% The id names the checkout directory (corpus/<id>): one that could leave it,
%% or collide with another, is refused.
a_malformed_id_refuses_the_list_test() ->
    [with_list([entry(Bad)], fun() ->
         ?assertEqual({error, {malformed_id, Bad}}, corpus_repos_config:read())
     end)
     || Bad <- [<<"../etc">>, <<"Macula">>, <<"-x">>, <<"a/b">>, <<>>]].

a_duplicate_id_refuses_the_list_test() ->
    with_list([entry(<<"a">>), entry(<<"a">>)], fun() ->
        ?assertEqual({error, {duplicate_id, <<"a">>}}, corpus_repos_config:read())
    end).

%% https, or an absolute path on the box (a local mirror); nothing that
%% needs credentials and nothing relative.
an_unsupported_url_refuses_the_list_test() ->
    [with_list([(entry(<<"a">>))#{<<"url">> => Bad}], fun() ->
         ?assertEqual({error, {unsupported_url, <<"a">>, Bad}}, corpus_repos_config:read())
     end)
     || Bad <- [<<"http://github.com/x/a.git">>, <<"git@github.com:x/a.git">>, <<"srv/a">>,
               <<"file:///srv/a">>]].

an_unknown_key_refuses_the_list_test() ->
    with_list([(entry(<<"a">>))#{<<"tag">> => <<"v1">>}], fun() ->
        ?assertEqual({error, {unknown_key, <<"a">>, <<"tag">>}}, corpus_repos_config:read())
    end).

%% MCL_RAG_CORPUS_REPOS names the list first, then the app env, then the
%% default mount.
the_env_var_names_the_list_first_test() ->
    with_list([entry(<<"from-app-env">>)], fun() ->
        Path = write_list([entry(<<"from-env">>)]),
        os:putenv("MCL_RAG_CORPUS_REPOS", Path),
        try
            ?assertMatch({ok, [#{id := <<"from-env">>}]}, corpus_repos_config:read())
        after
            os:unsetenv("MCL_RAG_CORPUS_REPOS"),
            file:delete(Path)
        end,
        ?assertMatch({ok, [#{id := <<"from-app-env">>}]}, corpus_repos_config:read())
    end).

a_local_mirror_is_a_source_test() ->
    with_list([(entry(<<"a">>))#{<<"url">> => <<"/srv/mirrors/a.git">>}], fun() ->
        ?assertMatch({ok, [#{url := <<"/srv/mirrors/a.git">>}]}, corpus_repos_config:read())
    end).

the_default_is_the_mount_test() ->
    Was = application:get_env(mcl_rag, corpus_repos_config),
    application:unset_env(mcl_rag, corpus_repos_config),
    try ?assertEqual("/etc/mcl-rag/corpus-repos.json", corpus_repos_config:path())
    after restore(Was)
    end.

%% The published schema and the refusals above are one set of rules: the
%% schema's required keys, closed key set and patterns are the ones read/0
%% enforces.
the_published_schema_is_the_rules_read_enforces_test() ->
    {ok, Bin} = file:read_file(schema_path()),
    #{<<"$defs">> := #{<<"repo">> := Repo}} = jsx:decode(Bin, [return_maps]),
    #{required := Required, patterns := Patterns} = corpus_repos_config:rules(),
    ?assertEqual(lists:sort(Required), lists:sort(maps:get(<<"required">>, Repo))),
    ?assertEqual(false, maps:get(<<"additionalProperties">>, Repo)),
    ?assertEqual(lists:sort(Required), lists:sort(maps:keys(maps:get(<<"properties">>, Repo)))),
    [?assertEqual(Pattern, maps:get(<<"pattern">>, maps:get(Key, maps:get(<<"properties">>, Repo))))
     || {Key, Pattern} <- maps:to_list(Patterns)].

entry(Id) ->
    #{<<"id">> => Id, <<"url">> => <<"https://github.com/x/", Id/binary, ".git">>,
      <<"branch">> => <<"main">>}.

with_list(Entries, Test) ->
    Path = write_list(Entries),
    Was = application:get_env(mcl_rag, corpus_repos_config),
    ok = application:set_env(mcl_rag, corpus_repos_config, Path),
    try Test()
    after
        restore(Was),
        file:delete(Path)
    end.

write_list(Entries) ->
    Path = filename:join(std_tmp(), "corpus-repos-" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".json"),
    ok = file:write_file(Path, jsx:encode(#{<<"repos">> => Entries})),
    Path.

schema_path() -> repo_file("schema/corpus-repos.schema.json").

%% Relative to the beam, not the working directory eunit happens to run in.
repo_file(Name) -> climb(filename:dirname(code:which(?MODULE)), Name, 8).

climb(_Dir, Name, 0) -> error({not_found, Name});
climb(Dir, Name, N) ->
    Candidate = filename:join(Dir, Name),
    case filelib:is_file(Candidate) of
        true  -> Candidate;
        false -> climb(filename:dirname(Dir), Name, N - 1)
    end.

restore(undefined) -> application:unset_env(mcl_rag, corpus_repos_config);
restore({ok, V})   -> application:set_env(mcl_rag, corpus_repos_config, V).

std_tmp() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Dir -> Dir
    end.
