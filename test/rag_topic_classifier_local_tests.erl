%%% @doc The topic classifier on the node's own ollama (Raf, 2026-09-29).
%%%
%%% One backend: msi00's ollama on loopback, through its OpenAI-compatible
%%% chat endpoint, with a local model. No hosted LLM, no API key, no second
%%% backend: nothing leaves the box, and a failure is returned as it is.
%%% `httpc' is mocked so no network is touched; every request is recorded so
%%% the tests can say what was asked, where, with which model and headers.
-module(rag_topic_classifier_local_tests).

-include_lib("eunit/include/eunit.hrl").

-define(LOCAL, <<"http://127.0.0.1:11434/v1/chat/completions">>).
-define(MODEL, <<"qwen2.5:7b-instruct-q4_K_M">>).

classifier_test_() ->
    {foreach, fun setup/0, fun teardown/1,
     [fun enabling_it_is_all_the_configuration_it_needs/0,
      fun it_is_the_local_ollama_and_its_model_by_default/0,
      fun it_asks_once_and_sends_no_credentials/0,
      fun a_failure_is_returned_as_it_is_and_nothing_is_asked_again/0,
      fun disabled_it_is_not_configured/0]}.

setup() ->
    Was = application:get_env(mcl_rag, topic_classifier),
    meck:new(httpc, [unstick, passthrough]),
    meck:expect(httpc, request, fun mock_request/4),
    erase(answers), erase(asked),
    Was.

teardown(Was) ->
    meck:unload(httpc),
    restore(Was).

restore(undefined)   -> application:unset_env(mcl_rag, topic_classifier);
restore({ok, Value}) -> application:set_env(mcl_rag, topic_classifier, Value).

enabling_it_is_all_the_configuration_it_needs() ->
    application:set_env(mcl_rag, topic_classifier, #{enabled => true}),
    ?assert(rag_topic_classifier:configured()).

it_is_the_local_ollama_and_its_model_by_default() ->
    application:set_env(mcl_rag, topic_classifier, #{enabled => true}),
    Backend = rag_topic_classifier:backend(),
    ?assertMatch(#{endpoint := ?LOCAL, model := ?MODEL}, Backend),
    ?assertNot(maps:is_key(api_key, Backend)).

it_asks_once_and_sends_no_credentials() ->
    application:set_env(mcl_rag, topic_classifier, #{enabled => true}),
    answer(?LOCAL, ok),
    ?assertEqual({ok, [<<"erlang">>, <<"mesh">>]}, rag_topic_classifier:classify(<<"some text">>, 3)),
    [{Url, Model, Headers}] = asked(),
    ?assertEqual(?LOCAL, Url),
    ?assertEqual(?MODEL, Model),
    ?assertEqual(false, lists:keymember("Authorization", 1, Headers)).

a_failure_is_returned_as_it_is_and_nothing_is_asked_again() ->
    application:set_env(mcl_rag, topic_classifier, #{enabled => true}),
    answer(?LOCAL, {status, 503}),
    ?assertMatch({error, {api_error, 503, _}}, rag_topic_classifier:classify(<<"some text">>, 3)),
    ?assertEqual(1, length(asked())).

disabled_it_is_not_configured() ->
    application:set_env(mcl_rag, topic_classifier, #{enabled => false}),
    ?assertNot(rag_topic_classifier:configured()),
    ?assertEqual({error, classifier_not_configured}, rag_topic_classifier:classify(<<"anything">>, 3)).

%%% Fixture

answer(Endpoint, Reply) ->
    put(answers, [{binary_to_list(Endpoint), Reply} | stored(answers)]).

asked() ->
    lists:reverse(stored(asked)).

stored(Key) ->
    case get(Key) of
        undefined -> [];
        Values -> Values
    end.

mock_request(post, {Url, Headers, _ContentType, Body}, _HttpOpts, _Opts) ->
    Model = maps:get(<<"model">>, jsx:decode(iolist_to_binary(Body), [return_maps])),
    put(asked, [{list_to_binary(Url), Model, Headers} | stored(asked)]),
    reply(proplists:get_value(Url, stored(answers), {error, no_such_endpoint})).

reply(ok) ->
    Content = jsx:encode(#{<<"choices">> => [#{<<"message">> => #{
                              <<"content">> => <<"[\"Erlang\", \"mesh\"]">>}}]}),
    {ok, {{"HTTP/1.1", 200, "OK"}, [], binary_to_list(Content)}};
reply({status, Status}) ->
    {ok, {{"HTTP/1.1", Status, "Error"}, [], "{\"error\":\"nope\"}"}};
reply({error, Reason}) ->
    {error, Reason}.
