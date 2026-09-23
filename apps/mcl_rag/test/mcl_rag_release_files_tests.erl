%% @doc The release files, asserted against each other.
%%
%% The image, the compose file and the templated configs are four files that
%% describe one running node, and nothing in the build reads them together. A
%% `${VAR}' the image does not set and compose does not require renders as a
%% malformed term and the node refuses to boot; a store on no volume loses the
%% shared memory on the first recreate; a NIF built on the workstation links
%% glibc and never loads on alpine. Each was true of this repo once.
-module(mcl_rag_release_files_tests).

-include_lib("eunit/include/eunit.hrl").

%% Every variable relx substitutes at boot is supplied: by the image with a
%% default, or by compose, which refuses to start without it.
every_templated_variable_is_supplied_test() ->
    Templated = lists:usort(vars_in("config/sys.config.src") ++ vars_in("config/vm.args.src")),
    Supplied = lists:usort(image_env() ++ compose_env()),
    ?assertEqual([], Templated -- Supplied).

%% The realm NAME joins the federation; its SHA-256 must be MCL_REALM, so a
%% default for either would be a guess. Compose demands both.
compose_demands_the_realm_name_test() ->
    ?assertMatch({match, _},
                 re:run(read("deploy/docker-compose.yml"),
                        <<"MCL_REALM_NAME=\\$\\{MCL_REALM_NAME:\\?">>)).

%% The corpus-sync NIF is compiled in the builder stage, against musl, before
%% the release is assembled. A copied-in binary built elsewhere links glibc.
the_image_builds_the_corpus_sync_nif_test() ->
    Text = read("Containerfile"),
    {Nif, _} = position(Text, <<"RUN bash scripts/build-corpus-sync-nif.sh">>),
    {Rel, _} = position(Text, <<"rebar3 as prod release">>),
    ?assert(Nif < Rel).

%% The store lives on a named volume at the data dir the image points at.
the_store_is_on_a_named_volume_test() ->
    {ok, [Dir]} = image_value(<<"MCL_DATA_DIR">>),
    Compose = read("deploy/docker-compose.yml"),
    ?assertMatch({match, _}, re:run(Compose, <<"- data:", Dir/binary, "\\s">>)),
    ?assertMatch({match, _}, re:run(Compose, <<"\\n  data:\\n    name: mcl-rag-data\\n">>)),
    ?assertMatch({match, _}, re:run(read("Containerfile"), <<"VOLUME .*\"", Dir/binary, "\"">>)).

%% The corpus list is mounted read-only where corpus_repos_config reads it by
%% default, so the file in this repo is the list the node syncs.
the_corpus_list_is_mounted_where_it_is_read_test() ->
    ok = application:unset_env(mcl_rag, corpus_repos_config),
    Path = list_to_binary(corpus_repos_config_default()),
    ?assertMatch({match, _},
                 re:run(read("deploy/docker-compose.yml"),
                        <<"- \\./corpus-repos\\.json:", Path/binary, ":ro">>)).

%% Opening the store rebuilds the vector index: over three minutes on the
%% workstation, longer on a Celeron, and /health is degraded throughout. The
%% start period has to outlast it or the orchestrator kills a healthy open.
the_health_check_waits_out_the_store_open_test() ->
    {match, [Secs]} = re:run(read("Containerfile"), <<"--start-period=([0-9]+)s">>,
                             [{capture, all_but_first, binary}]),
    ?assert(binary_to_integer(Secs) >= 900).

%% Host networking makes every port fleet-wide, so the registry
%% (macula-fleet PORTS.md: health 8450, API 8451) is the only authority, and
%% the image, compose and the app's own default must all say the same thing.
%% The image once said 8470, which is mcl-sentinel's.
the_ports_are_the_registered_ones_test() ->
    %% The .app file's own default, read from the file: once loaded, the env
    %% (get_env and get_key alike) carries test.sys.config's value.
    {ok, [{application, mcl_rag, Spec}]} = file:consult(code:where_is_file("mcl_rag.app")),
    Default = proplists:get_value(http_port, proplists:get_value(env, Spec)),
    ?assertEqual({ok, [<<"8451">>]}, image_value(<<"MCL_RAG_HTTP_PORT">>)),
    ?assertEqual(8451, Default),
    ?assertEqual({ok, [<<"8450">>]}, image_value(<<"MCL_HEALTH_PORT">>)),
    Compose = read("deploy/docker-compose.yml"),
    ?assertMatch({match, _}, re:run(Compose, <<"- MCL_RAG_HTTP_PORT=8451\\n">>)),
    ?assertMatch({match, _}, re:run(Compose, <<"- MCL_HEALTH_PORT=8450\\n">>)),
    ?assertMatch({match, _}, re:run(read("Containerfile"), <<"EXPOSE 8450 8451\\n">>)).

%% relx puts in the release only what an `applications' list reaches, while
%% the test code path holds every rebar dep. An app called directly but not
%% listed passes every suite and is `undef' in production: macula_rag was
%% (join_federation), and dialyzer, not a test, noticed.
every_directly_called_app_is_listed_test() ->
    [?assert(lists:member(Dep, applications(App)))
     || {App, Dep} <- [{mcl_rag, macula_rag}, {mcl_rag, ranch}, {rag, barrel_embed}]].

%%==============================================================================

applications(App) ->
    _ = application:load(App),
    {ok, Apps} = application:get_key(App, applications),
    Apps.

corpus_repos_config_default() ->
    {ok, Text} = file:read_file(src("sync_corpus/corpus_repos_config.erl")),
    {match, [P]} = re:run(Text, <<"corpus_repos_config,\\s*\"([^\"]+)\"">>,
                          [{capture, all_but_first, list}]),
    P.

%% Comment lines are skipped: they name `${VAR}' in prose, not in config.
vars_in(File) ->
    Config = re:replace(read(File), <<"(?m)^\\s*(%|#).*$">>, <<>>, [global, {return, binary}]),
    case re:run(Config, <<"\\$\\{([A-Z0-9_]+)\\}">>,
                [global, {capture, all_but_first, binary}]) of
        {match, Ms} -> [V || [V] <- Ms];
        nomatch -> []
    end.

image_env() ->
    {match, Ms} = re:run(read("Containerfile"), <<"(?m)^ENV ([A-Z0-9_]+)=">>,
                         [global, {capture, all_but_first, binary}]),
    [V || [V] <- Ms].

image_value(Name) ->
    case re:run(read("Containerfile"), <<"(?m)^ENV ", Name/binary, "=(\\S+)">>,
                [{capture, all_but_first, binary}]) of
        {match, V} -> {ok, V};
        nomatch -> {error, {not_in_image, Name}}
    end.

compose_env() ->
    {match, Ms} = re:run(read("deploy/docker-compose.yml"), <<"(?m)^\\s+- ([A-Z0-9_]+)=">>,
                         [global, {capture, all_but_first, binary}]),
    [V || [V] <- Ms].

position(Text, Needle) ->
    case binary:match(Text, Needle) of
        nomatch -> error({not_found, Needle});
        Found -> Found
    end.

read(Name) ->
    {ok, Text} = file:read_file(alongside(Name)),
    Text.

src(Rel) -> alongside(filename:join("apps/mcl_rag/src", Rel)).

%% Relative to the beam rather than the working directory, because eunit runs
%% from wherever the developer happens to be standing.
alongside(Name) -> climb(filename:dirname(code:which(?MODULE)), Name, 8).

climb(_Dir, Name, 0) -> Name;
climb(Dir, Name, Left) ->
    Candidate = filename:join(Dir, Name),
    found(filelib:is_regular(Candidate), Candidate, Dir, Name, Left).

found(true, Candidate, _Dir, _Name, _Left) -> Candidate;
found(false, _Candidate, Dir, Name, Left) ->
    climb(filename:dirname(Dir), Name, Left - 1).
