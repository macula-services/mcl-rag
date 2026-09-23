%%% @doc This node is one shard of the org's federated retrieval (macula_rag).
%%%
%%% It answers the org's `mcl-rag/rag.query_shard_v1' by embedding the query
%%% text with its own embedder and searching its own store; it joins once
%%% mcl_om's pool and realm exist, naming the embedding its vectors were built
%%% with; and /health says when the org cannot reach it.
-module(serve_federated_query_tests).

-include_lib("eunit/include/eunit.hrl").

-define(REALM_NAME, <<"io.macula">>).
-define(REALM, crypto:hash(sha256, ?REALM_NAME)).
-define(POOL, whereis(init)). %% any stable pid: the mock runs in the joining process
-define(VECTOR, [0.5, 0.25]).

%%------------------------------------------------------------------------------
%% The resolved library
%%------------------------------------------------------------------------------

%% 0.1.0 is the release whose API this module is written against.
the_resolved_macula_rag_is_0_1_test() ->
    ok = application:load(macula_rag),
    {ok, Vsn} = application:get_key(macula_rag, vsn),
    ?assertMatch("0.1." ++ _, Vsn),
    {module, _} = code:ensure_loaded(macula_rag),
    [?assert(erlang:function_exported(macula_rag, F, A))
     || {F, A} <- [{configure, 3}, {register_responder, 1}, {advertise, 2}, {status, 0}]].

%%------------------------------------------------------------------------------
%% Answering a shard query
%%------------------------------------------------------------------------------

a_query_is_embedded_here_and_searched_here_test() ->
    with_store(fun() ->
        {ok, [Hit]} = answer_federated_query:answer(#{<<"text">> => <<"federated">>}, #{top_k => 3}),
        ?assertEqual(1, meck:num_calls(rag_embedder, embed, [<<"federated">>])),
        ?assertEqual(1, meck:num_calls(rag_store, search_vector, [?VECTOR, 3])),
        ?assertEqual(#{id => <<"c1">>, score => 0.9, content => <<"body">>,
                       source_path => <<"a.md">>}, Hit)
    end).

%% Every hit carries the contract's minimum, or macula_rag refuses the answer.
every_hit_meets_the_contract_test() ->
    with_store(fun() ->
        {ok, Hits} = answer_federated_query:answer(#{<<"text">> => <<"q">>}, #{top_k => 3}),
        ?assert(lists:all(fun macula_rag_contract:valid_hit/1, Hits))
    end).

a_query_without_text_is_refused_test() ->
    with_store(fun() ->
        ?assertEqual({error, missing_text},
                     answer_federated_query:answer(#{<<"vector">> => ?VECTOR}, #{top_k => 3}))
    end).

%% The asking node sees why this shard did not answer.
a_refusal_is_the_answer_test() ->
    with_store(fun() ->
        ok = meck:expect(rag_store, search_vector, fun(_, _) -> {error, store_opening} end),
        ?assertEqual({error, store_opening},
                     answer_federated_query:answer(#{<<"text">> => <<"q">>}, #{top_k => 3})),
        ok = meck:expect(rag_embedder, embed, fun(_) -> {error, timeout} end),
        ?assertEqual({error, timeout},
                     answer_federated_query:answer(#{<<"text">> => <<"q">>}, #{top_k => 3}))
    end).

%%------------------------------------------------------------------------------
%% Joining
%%------------------------------------------------------------------------------

%% The org, realm name and embedding come from config; the shard id defaults
%% to the node name.
joining_configures_answers_and_summarizes_test() ->
    with_federation(fun() ->
        ok = await_status(joined),
        [{_, {macula_rag, configure, [Pool, Realm, Opts]}, ok}] = calls(configure),
        ?assertEqual({?POOL, ?REALM}, {Pool, Realm}),
        ?assertEqual(#{org => <<"mcl-rag">>, shard_id => atom_to_binary(node()),
                       realm_name => ?REALM_NAME,
                       embedding => #{model => <<"intfloat/multilingual-e5-small">>, dim => 384}},
                     Opts),
        ?assertEqual(1, meck:num_calls(macula_rag, register_responder,
                                       [fun answer_federated_query:answer/2])),
        ?assertEqual(1, meck:num_calls(macula_rag, advertise, [[], <<>>]))
    end).

%% mcl_om's pool may not exist yet when the service starts: wait for it.
joining_waits_for_the_pool_test() ->
    with_federation(fun() ->
        ok = meck:expect(mcl_om, macula_client, fun() -> {error, no_client} end),
        ok = restart_join(),
        ?assertEqual({waiting, no_client}, join_federation:status()),
        ok = meck:expect(mcl_om, macula_client, fun() -> {ok, ?POOL} end),
        ok = await_status(joined)
    end).

%% A configuration macula_rag refuses (a realm name that is not this realm's)
%% is not retried: it will not fix itself.
a_refused_configuration_is_named_test() ->
    with_federation(fun() ->
        ok = meck:expect(macula_rag, configure,
                         fun(_, _, _) -> {error, {realm_name_mismatch, <<"x">>}} end),
        ok = restart_join(),
        ok = await_status({refused, {realm_name_mismatch, <<"x">>}})
    end).

%%------------------------------------------------------------------------------
%% /health
%%------------------------------------------------------------------------------

health_is_ok_when_the_org_can_reach_this_shard_test() ->
    ?assertEqual(ok, federation_health(joined, granted)).

%% The same grace mcl_om gives its own procedures' grants (60 s by default).
a_grant_still_inside_its_grace_is_ok_test() ->
    ?assertEqual(ok, federation_health(joined, {not_granted, #{reason => r, since_ms => 1000}})).

a_grant_refused_past_its_grace_is_degraded_test() ->
    Status = #{responder => {not_granted, #{reason => r, since_ms => 61000}}},
    ?assertMatch({degraded, #{federation := Status}},
                 federation_health(joined, {not_granted, #{reason => r, since_ms => 61000}})).

not_yet_joined_is_degraded_test() ->
    ?assertEqual({degraded, #{federation => {waiting, no_client}}},
                 federation_health({waiting, no_client}, not_registered)).

a_refused_configuration_is_down_test() ->
    ?assertEqual({down, #{federation => {refused, bad}}},
                 federation_health({refused, bad}, not_registered)).

%%------------------------------------------------------------------------------
%% helpers
%%------------------------------------------------------------------------------

federation_health(Joined, Responder) ->
    join_federation:health(Joined, #{responder => Responder}).

with_store(Test) ->
    ok = meck:new(rag_embedder, [passthrough, no_link]),
    ok = meck:new(rag_store, [no_link]),
    ok = meck:expect(rag_embedder, embed, fun(_) -> {ok, ?VECTOR} end),
    ok = meck:expect(rag_store, search_vector, fun(_, _) ->
        {ok, [#{chunk_id => <<"c1">>, score => 0.9, content => <<"body">>,
                source_path => <<"a.md">>, meta => #{<<"kind">> => <<"prose">>}}]}
    end),
    try Test() after meck:unload([rag_embedder, rag_store]) end.

with_federation(Test) ->
    ok = meck:new(mcl_om, [no_link]),
    ok = meck:new(macula_rag, [no_link]),
    ok = meck:expect(mcl_om, macula_client, fun() -> {ok, ?POOL} end),
    ok = meck:expect(mcl_om, realm, fun() -> {ok, ?REALM} end),
    ok = meck:expect(macula_rag, configure, fun(_, _, _) -> ok end),
    ok = meck:expect(macula_rag, register_responder, fun(_) -> ok end),
    ok = meck:expect(macula_rag, advertise, fun(_, _) -> ok end),
    ok = application:set_env(mcl_rag, federation, #{realm_name => ?REALM_NAME}),
    ok = application:set_env(mcl_om, org, <<"mcl-rag">>),
    ok = application:set_env(mcl_rag, embed_model, <<"intfloat/multilingual-e5-small">>),
    ok = application:set_env(mcl_rag, embed_dim, 384),
    try
        {ok, Pid} = join_federation:start_link(#{retry_ms => 20}),
        unlink(Pid),
        Test()
    after
        stop(join_federation),
        meck:unload([mcl_om, macula_rag]),
        [application:unset_env(mcl_rag, K) || K <- [federation, embed_model, embed_dim]]
    end.

restart_join() ->
    stop(join_federation),
    meck:reset(macula_rag),
    {ok, Pid} = join_federation:start_link(#{retry_ms => 20}),
    unlink(Pid),
    ok.

stop(Name) ->
    stopped(whereis(Name)).

stopped(undefined) -> ok;
stopped(Pid) ->
    Ref = monitor(process, Pid),
    exit(Pid, shutdown),
    receive {'DOWN', Ref, process, Pid, _} -> ok after 5000 -> ok end.

calls(F) -> [C || {_, {_, Fun, _}, _} = C <- meck:history(macula_rag), Fun =:= F].

await_status(Want) -> await_status(Want, 100).
await_status(Want, 0) -> {still, join_federation:status(), not_, Want};
await_status(Want, N) ->
    case join_federation:status() of
        Want -> ok;
        _    -> timer:sleep(20), await_status(Want, N - 1)
    end.
