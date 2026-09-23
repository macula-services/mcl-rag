%% @doc The service contract, asserted locally.
%%
%% mcl_om resolves its six callbacks BY NAME at startup, on a live node, so a
%% service that forgets one dies with `undef' where nobody is watching. The
%% primary defence is the `-behaviour(mcl_om_service)' attribute on the
%% service module, which turns a missing callback into a compile error under
%% warnings_as_errors.
%%
%% What this suite adds is everything the compiler cannot see: that the attribute
%% has not been quietly dropped, that the values inside those callbacks are the
%% shapes mcl_om will destructure, and that the names and version this service
%% reports are the ones it actually has. Nothing local boots mcl_om, so
%% asserting the shape by hand is the closest available thing to a rehearsal.
-module(mcl_rag_service_tests).

-include_lib("eunit/include/eunit.hrl").

-define(APP, mcl_rag).
-define(SERVICE, mcl_rag_service).

%% Belt and braces with the behaviour attribute, and it survives the attribute
%% being removed. If mcl_om ever adds a SEVENTH required callback this test
%% keeps passing and the deploy still breaks, which is the honest limit of a
%% local assertion about a remote contract.
exports_every_required_callback_test() ->
    _ = code:ensure_loaded(?SERVICE),
    Required = [{info, 0}, {start, 1}, {stop, 1},
                {health, 0}, {capabilities, 0}, {identity_spec, 0}],
    Missing = [F || {N, A} = F <- Required,
                    not erlang:function_exported(?SERVICE, N, A)],
    ?assertEqual([], Missing).

info_carries_the_three_keys_test() ->
    #{name := Name, version := Vsn, description := Desc} = ?SERVICE:info(),
    ?assert(is_binary(Name)),
    ?assert(is_binary(Vsn)),
    ?assert(is_binary(Desc)),
    ?assertEqual(<<"mcl-rag">>, Name).

%% THE TWO NAMES MUST AGREE. The OTP application is snake_case because it is an
%% Erlang atom; the repository, the container image and the name this service
%% answers to on the mesh are kebab-case. They describe one service, so a
%% scaffold generated with a mismatched pair is caught here on the first eunit
%% run rather than by a puzzled reader months later.
mesh_name_matches_the_application_test() ->
    #{name := Wire} = ?SERVICE:info(),
    Snake = atom_to_binary(?APP, utf8),
    ?assertEqual(binary:replace(Snake, <<"_">>, <<"-">>, [global]), Wire).

%% The version in info/0 is what a peer reads off /health, so it disagreeing with
%% the application it describes is a lie that nothing else would catch.
info_version_matches_the_application_test() ->
    _ = application:load(?APP),
    {ok, Vsn} = application:get_key(?APP, vsn),
    #{version := Reported} = ?SERVICE:info(),
    ?assertEqual(list_to_binary(Vsn), Reported).

%%==============================================================================
%% The contract callers dial
%%==============================================================================

-define(PROCEDURES,
        [<<"add_knowledge">>, <<"answer_query">>, <<"classify_topics">>,
         <<"detect_corpus_change">>, <<"embed_document">>, <<"get_chunk_by_id">>,
         <<"get_document_verbatim">>, <<"get_source_by_id">>, <<"ingest_document">>,
         <<"list_chunks_by_source">>, <<"list_sources_page">>, <<"prune_chunks">>,
         <<"rerank_results">>, <<"retire_document">>, <<"schedule_reembed">>,
         <<"search_chunks_semantic">>, <<"upload_knowledge">>]).

%% The seventeen procedures, org-qualified the way mcl_om registers them:
%% `mcl-rag/<name>'. macula-mcp's mesh_recall/mesh_remember, macula-cli and
%% macula-lazymesh are built against these. A change is a new name.
the_procedures_are_the_published_contract_test() ->
    ?assertEqual([<<"mcl-rag/", N/binary>> || N <- ?PROCEDURES],
                 lists:sort([mcl_om_capabilities:org_procedure(<<"mcl-rag">>, Name)
                             || #{name := Name} <- ?SERVICE:capabilities()])).

%% Each is served through mcl_om's simple handler into the mesh RPC router,
%% under a handler function named after the procedure.
every_procedure_routes_to_its_handler_test() ->
    [?assertEqual({mcl_om_simple_handler,
                   {mcl_rag_mesh_rpc, binary_to_atom(<<"handle_", N/binary>>)}},
                  H)
     || #{name := N, handler := H} <- ?SERVICE:capabilities()],
    [?assert(erlang:function_exported(mcl_rag_mesh_rpc, F, 1))
     || #{handler := {_, {_, F}}} <- ?SERVICE:capabilities(),
        {module, _} <- [code:ensure_loaded(mcl_rag_mesh_rpc)]].

the_shipped_config_names_the_org_test() ->
    {ok, Text} = file:read_file(alongside("config/sys.config.src")),
    ?assertNotEqual(nomatch, binary:match(Text, <<"{org,               <<\"mcl-rag\">>}">>)).

%% The corpus the shared memory holds: which repos corpus_git_sync keeps
%% checked out under <data_dir>/corpus/<id>. The ids are the checkout
%% directories AND the namespace of every stored watermark, so a renamed id
%% re-embeds that repo from scratch. The list lived only on beam03 and is
%% rebuilt from the checkouts in the data copy; it must read back through the
%% real reader.
the_shipped_corpus_list_reads_back_test() ->
    ok = application:set_env(mcl_rag, corpus_repos_config, alongside("deploy/corpus-repos.json")),
    try
        {ok, Repos} = corpus_repos_config:read(),
        ?assertEqual([<<"faber-ecosystem">>, <<"hecate-corpus">>, <<"hecate-ecosystem">>,
                      <<"macula">>, <<"macula-cli">>, <<"macula-dotnet">>, <<"macula-ecosystem">>,
                      <<"macula-go">>, <<"macula-mcp">>, <<"macula-php">>, <<"macula-py">>,
                      <<"macula-rust">>, <<"macula-ts">>, <<"reckon-ecosystem">>],
                     lists:sort([Id || #{id := Id} <- Repos])),
        [?assertMatch(#{url := <<"https://github.com/", _/binary>>, branch := <<_, _/binary>>}, R)
         || R <- Repos]
    after
        application:unset_env(mcl_rag, corpus_repos_config)
    end.

%%==============================================================================
%% Health and authority
%%==============================================================================

%% The D25 provider grant for each procedure is reported by mcl_om itself;
%% the service's own verdict is its store. Opening rebuilds the vector index,
%% minutes on the production corpus, and every call is refused meanwhile, so
%% /health says so rather than reporting a service that answers nothing.
the_service_is_healthy_once_its_store_is_open_test() ->
    with_store_status(open, fun() -> ?assertEqual(ok, ?SERVICE:health()) end).

health_is_degraded_while_the_store_opens_test() ->
    with_store_status(opening, fun() ->
        ?assertEqual({degraded, store_opening}, ?SERVICE:health())
    end).

%% Once the store serves, the verdict is whether the org can reach this shard
%% (join_federation:health/0, macula_rag's own grant): its procedure is not one
%% of mcl_om's seventeen, so mcl_om's provider_grants never lists it.
health_names_a_shard_the_org_cannot_reach_test() ->
    Unreachable = {degraded, #{federation => {waiting, no_client}}},
    with_store_status(open, Unreachable, fun() ->
        ?assertEqual(Unreachable, ?SERVICE:health())
    end).

%% The store's own verdict comes first: a shard whose store is opening cannot
%% answer whatever its grant says.
the_store_opening_wins_over_federation_test() ->
    with_store_status(opening, {degraded, #{federation => {waiting, no_client}}}, fun() ->
        ?assertEqual({degraded, store_opening}, ?SERVICE:health())
    end).

%% A store that is not running is down, not a crash of /health.
health_is_down_without_a_store_test() ->
    ?assertEqual(undefined, whereis(rag_store)),
    ?assertEqual({down, store_not_running}, ?SERVICE:health()).

%% A registered stand-in for the store process, answering `Status', and a
%% federation verdict.
with_store_status(Status, Test) ->
    with_store_status(Status, ok, Test).

with_store_status(Status, Federation, Test) ->
    Stand = spawn(fun() -> receive stop -> ok end end),
    true = register(rag_store, Stand),
    ok = meck:new(rag_store, [passthrough, no_link]),
    ok = meck:expect(rag_store, status, fun() -> Status end),
    ok = meck:new(join_federation, [passthrough, no_link]),
    ok = meck:expect(join_federation, health, fun() -> Federation end),
    try Test() after meck:unload([rag_store, join_federation]), Stand ! stop end.

the_resolved_mcl_om_reports_provider_grants_test() ->
    {module, _} = code:ensure_loaded(mcl_om_capabilities),
    ?assert(erlang:function_exported(mcl_om_capabilities, provider_grants, 0)).

identity_spec_asks_for_nothing_test() ->
    #{actions := Actions, resources := Resources} = ?SERVICE:identity_spec(),
    ?assertEqual([], Actions),
    ?assertEqual([], Resources).

%% A malformed operator list would otherwise surface on the first destructive
%% call, as a crash in the gate. It is refused at start instead.
start_refuses_a_malformed_operator_list_test() ->
    ok = application:set_env(?APP, operators, "not-a-node-id"),
    try ?assertError({invalid_rag_operators, {not_64_hex, _}}, ?SERVICE:start(#{}))
    after application:unset_env(?APP, operators)
    end.

%%==============================================================================
%% The local HTTP API
%%==============================================================================

%% The API includes writes (add, upload, retire) and has no authentication of
%% its own; the container runs on host networking. Loopback by default.
the_http_api_binds_loopback_by_default_test() ->
    ok = application:unset_env(?APP, http_ip),
    ?assertEqual({127, 0, 0, 1}, proplists:get_value(ip, mcl_rag_sup:socket_opts())).

%%==============================================================================
%% The runtime is pinned in two places, and neither is the one you are running
%%==============================================================================

%% ⚠ THIS GUARD EXISTS BECAUSE A SIBLING SERVICE DID NOT HAVE IT, AND IT COST
%% THREE COMMITS AND AN IMAGE THAT SHIPPED ANYWAY.
%%
%% Its `Containerfile' said 27 while development ran on 28. So `rebar3 eunit'
%% passing locally meant "passing on 28" and nothing more, CI failed on a crash
%% that does not occur on 28 at all, and because the image build is a separate
%% workflow the image went to the fleet regardless.
%%
%% The release is pinned in TWO files, and the version actually running is a
%% third thing that agrees with neither by default. **A comment in each file
%% saying they must match is not a mechanism**, and both files carried one.
%%
%% ⚠⚠ IT FAILS RATHER THAN WARNS WHEN YOUR VM DIFFERS, AND THAT IS DELIBERATE.
%% Developing on a release you do not ship makes a green suite mean less than it
%% appears to. If you want to work on another release, move both pins and find
%% out what breaks, which is the whole point of having them.
%%
%% ⚠ TO THE PATCH, AND NOTHING FLOATS. This compared majors only, so when Docker
%% Hub moved the floating `erlang:28-alpine' on 2026-09-22 a service generated
%% from this template shipped OTP 28.5 and its guard stayed green. It compares
%% the full release now: the builder's (which must also carry a digest, so a
%% re-pushed tag cannot change what builds), lint's image and the release its
%% toolchain step insists on, .tool-versions, and this VM. Lint's image itself
%% is a dated CI image, so it is held to its digest separately.
the_runtime_agrees_between_the_image_the_ci_and_this_vm_test() ->
    Image = pinned("Containerfile",
                   "^FROM docker\\.io/(?:hexpm/)?erlang:([0-9]+\\.[0-9]+\\.[0-9]+)"
                   "-alpine[^@\\s]*@sha256:[0-9a-f]{64} AS builder$"),
    CiCheck = pinned(".github/workflows/lint.yml",
                     "\\{<<\"([0-9]+\\.[0-9]+\\.[0-9]+)\">>, true\\} -> halt\\(0\\);"),
    Tools = pinned(".tool-versions", "^erlang ([0-9]+\\.[0-9]+\\.[0-9]+)$"),
    %% Sorted and deduplicated, so a failure prints every version rather than
    %% the first pair that happened to be compared.
    ?assertEqual([Image], lists:usort([Image, CiCheck, Tools, running_otp()])).

%% Lint runs in the shared CI image, whose tag is a build date, not a release:
%% the release is what its toolchain step insists on (above). What keeps it
%% from floating is the digest.
the_ci_image_is_pinned_by_digest_test() ->
    ?assertMatch(<<_/binary>>,
                 pinned(".github/workflows/lint.yml",
                        "^\\s+image: (ghcr\\.io/macula-io/macula-ci-otp:[0-9]{8}-[0-9]{4})"
                        "@sha256:[0-9a-f]{64}$")).

%% The full release, 28.4.3 and not 28: `otp_release' names only the major.
running_otp() ->
    {ok, Version} = file:read_file(filename:join([code:root_dir(), "releases",
                                                  erlang:system_info(otp_release),
                                                  "OTP_VERSION"])),
    string:trim(Version).

pinned(Relative, Pattern) ->
    {ok, Text} = file:read_file(alongside(Relative)),
    {match, [Version]} = re:run(Text, Pattern,
                                [multiline, {capture, all_but_first, binary}]),
    Version.

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
