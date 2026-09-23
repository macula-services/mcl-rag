%%% @doc The topic classifier's second backend.
%%%
%%% NVIDIA's free endpoint answered 429 to every request for a day
%%% (2026-09-02/03). These pin what the classifier does about it: two
%%% backends of one shape, primary first, the next one asked when the
%%% first fails for a reason that is the backend's, and never when the
%%% request itself was refused. `httpc' is mocked so no network is
%%% touched; every request the classifier makes is recorded so the tests
%%% can say which backend was asked, in which order, for which model.
-module(rag_topic_classifier_fallback_tests).

-include_lib("eunit/include/eunit.hrl").

-define(PRIMARY, <<"https://primary.test/v1/chat/completions">>).
-define(FALLBACK, <<"https://fallback.test/v1/chat/completions">>).

classifier_test_() ->
    {foreach, fun setup/0, fun teardown/1,
     [fun a_keyless_backend_is_not_a_backend/0,
      fun the_primary_comes_first/0,
      fun a_node_holding_only_the_fallback_key_classifies_on_the_fallback/0,
      fun a_rate_limited_primary_hands_over_to_the_fallback/0,
      fun a_refused_connection_hands_over_too/0,
      fun a_bad_request_is_not_sent_again/0,
      fun both_failing_names_both/0]}.

setup() ->
    Was = application:get_env(mcl_rag, topic_classifier),
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun mock_request/4),
    Was.

teardown(Was) ->
    meck:unload(httpc),
    restore(Was).

restore(undefined)   -> application:unset_env(mcl_rag, topic_classifier);
restore({ok, Value}) -> application:set_env(mcl_rag, topic_classifier, Value).

%%% The backend list

a_keyless_backend_is_not_a_backend() ->
    configure(<<>>, <<>>),
    ?assertEqual([], rag_topic_classifier:backends()),
    ?assertNot(rag_topic_classifier:configured()),
    ?assertEqual({error, classifier_not_configured},
                 rag_topic_classifier:classify(<<"anything">>, 3)).

the_primary_comes_first() ->
    configure(<<"k-primary">>, <<"k-fallback">>),
    ?assertMatch([#{name := <<"primary">>, model := <<"openai/gpt-oss-20b">>},
                  #{name := <<"fallback">>, model := <<"deepseek-chat">>}],
                 rag_topic_classifier:backends()).

a_node_holding_only_the_fallback_key_classifies_on_the_fallback() ->
    configure(<<>>, <<"k-fallback">>),
    ?assertMatch([#{name := <<"fallback">>}], rag_topic_classifier:backends()),
    ?assert(rag_topic_classifier:configured()),
    answer(?FALLBACK, ok),
    ?assertEqual({ok, [<<"erlang">>, <<"mesh">>]},
                 rag_topic_classifier:classify(<<"some text">>, 3)),
    ?assertEqual([{?FALLBACK, <<"deepseek-chat">>}], asked()).

%%% Handing over

a_rate_limited_primary_hands_over_to_the_fallback() ->
    configure(<<"k-primary">>, <<"k-fallback">>),
    answer(?PRIMARY, {status, 429}),
    answer(?FALLBACK, ok),
    ?assertEqual({ok, [<<"erlang">>, <<"mesh">>]},
                 rag_topic_classifier:classify(<<"some text">>, 3)),
    ?assertEqual([{?PRIMARY, <<"openai/gpt-oss-20b">>},
                  {?FALLBACK, <<"deepseek-chat">>}], asked()).

a_refused_connection_hands_over_too() ->
    configure(<<"k-primary">>, <<"k-fallback">>),
    answer(?PRIMARY, {error, econnrefused}),
    answer(?FALLBACK, ok),
    ?assertEqual({ok, [<<"erlang">>, <<"mesh">>]},
                 rag_topic_classifier:classify(<<"some text">>, 3)),
    ?assertEqual([{?PRIMARY, <<"openai/gpt-oss-20b">>},
                  {?FALLBACK, <<"deepseek-chat">>}], asked()).

a_bad_request_is_not_sent_again() ->
    configure(<<"k-primary">>, <<"k-fallback">>),
    answer(?PRIMARY, {status, 400}),
    answer(?FALLBACK, ok),
    ?assertMatch({error, {api_error, 400, _}},
                 rag_topic_classifier:classify(<<"some text">>, 3)),
    ?assertEqual([{?PRIMARY, <<"openai/gpt-oss-20b">>}], asked()).

both_failing_names_both() ->
    configure(<<"k-primary">>, <<"k-fallback">>),
    answer(?PRIMARY, {status, 429}),
    answer(?FALLBACK, {status, 503}),
    ?assertEqual({error, {all_backends_failed, [{<<"primary">>, <<"http 429">>},
                                                {<<"fallback">>, <<"http 503">>}]}},
                 rag_topic_classifier:classify(<<"some text">>, 3)).

%%% Fixture

configure(PrimaryKey, FallbackKey) ->
    application:set_env(mcl_rag, topic_classifier,
                        #{enabled  => true,
                          api_key  => PrimaryKey,
                          endpoint => ?PRIMARY,
                          fallback => #{api_key => FallbackKey, endpoint => ?FALLBACK}}),
    erase(answers),
    erase(asked).

%% What each endpoint answers: `ok' (two topics), `{status, N}', or
%% `{error, Reason}' as httpc would return it.
answer(Endpoint, Reply) ->
    put(answers, [{binary_to_list(Endpoint), Reply} | answers()]).

answers() ->
    case get(answers) of undefined -> []; L -> L end.

asked() ->
    lists:reverse(case get(asked) of undefined -> []; L -> L end).

mock_request(post, {Url, _Headers, _ContentType, Body}, _HttpOpts, _Opts) ->
    put(asked, [{list_to_binary(Url), model_in(Body)} | case get(asked) of undefined -> []; L -> L end]),
    reply(proplists:get_value(Url, answers(), {error, no_such_endpoint})).

reply(ok) ->
    Content = jsx:encode(#{<<"choices">> => [#{<<"message">> => #{
                              <<"content">> => <<"[\"Erlang\", \"mesh\"]">>}}]}),
    {ok, {{"HTTP/1.1", 200, "OK"}, [], binary_to_list(Content)}};
reply({status, Status}) ->
    {ok, {{"HTTP/1.1", Status, "Error"}, [], "{\"error\":\"nope\"}"}};
reply({error, Reason}) ->
    {error, Reason}.

model_in(Body) ->
    maps:get(<<"model">>, jsx:decode(iolist_to_binary(Body), [return_maps])).
