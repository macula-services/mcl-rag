%%% @doc LLM-backed topic classifier, on the node's own ollama.
%%%
%%% Calls an OpenAI-compatible chat completion endpoint to classify text into
%%% 1-N topic labels, and returns them as lowercase binaries. The endpoint is
%%% the node's own ollama on loopback (Raf, 2026-09-29): no hosted LLM, no API
%%% key, nothing leaves the box. There is one backend, and a failure is
%%% returned as it is; nothing is asked again elsewhere.
%%%
%%% Config (under the `mcl_rag' app env):
%%%
%%%   {topic_classifier, #{
%%%       enabled  => true | false,       %% default false
%%%       endpoint => <<"http://127.0.0.1:11434/v1/chat/completions">>,
%%%       model    => <<"qwen2.5:7b-instruct-q4_K_M">>,
%%%       timeout  => 30000               %% ms
%%%   }}
%%%
%%% The reply's `choices[0].message.content' holds a JSON array, possibly
%%% wrapped in a markdown code block (stripped). No tool calling is needed,
%%% so any working chat model is fine here. Uses `httpc' (OTP's own).
-module(rag_topic_classifier).

-export([classify/2, classify_batch/2, configured/0, extract_topics/1]).
-export([backend/0]).

-define(DEFAULT_ENDPOINT, <<"http://127.0.0.1:11434/v1/chat/completions">>).
-define(DEFAULT_MODEL,    <<"qwen2.5:7b-instruct-q4_K_M">>).
-define(DEFAULT_TIMEOUT,  30000).

-define(PROMPT_TEMPLATE,
    <<"Classify this text into 1-~B topic labels. "
      "Return ONLY a JSON array of lowercase string labels, nothing else. "
      "Be specific and concise (1-3 words per label).~n~nText: ~ts">>).

-type topic() :: binary().
-type backend() :: #{endpoint := binary(), model := binary(), timeout := pos_integer()}.

%%% API

%% @doc Whether the classifier is switched on. It needs nothing else: the
%% endpoint and model default to the node's own ollama.
-spec configured() -> boolean().
configured() ->
    maps:get(enabled, topic_config(), false) =:= true.

%% @doc The one backend: the configured endpoint and model, the local
%% ollama's by default.
-spec backend() -> backend().
backend() ->
    Config = topic_config(),
    #{endpoint => maps:get(endpoint, Config, ?DEFAULT_ENDPOINT),
      model    => maps:get(model, Config, ?DEFAULT_MODEL),
      timeout  => maps:get(timeout, Config, ?DEFAULT_TIMEOUT)}.

-spec classify(binary(), pos_integer()) -> {ok, [topic()]} | {error, term()}.
classify(Text, MaxTopics) when is_binary(Text), is_integer(MaxTopics), MaxTopics > 0 ->
    case configured() of
        false -> {error, classifier_not_configured};
        true  -> do_classify(Text, MaxTopics)
    end.

-spec classify_batch([binary()], pos_integer()) -> {ok, [[topic()]]} | {error, term()}.
classify_batch(Texts, MaxTopics) when is_list(Texts) ->
    Results = lists:foldl(fun(Text, {Ok, Err}) ->
        batch_one(Text, MaxTopics, Ok, Err)
    end, {[], []}, Texts),
    batch_result(Results).

%%% Internal — batch

batch_one(Text, MaxTopics, Ok, Err) ->
    case classify(Text, MaxTopics) of
        {ok, Topics} -> {[{Text, Topics} | Ok], Err};
        {error, R}   -> {Ok, [{Text, R} | Err]}
    end.

batch_result({Ok, Err}) ->
    case {Ok, Err} of
        {[], [_ | _]} -> {error, {all_failed, Err}};
        _             -> {ok, [Topics || {_Text, Topics} <- lists:reverse(Ok)]}
    end.

%%% Internal — classify

do_classify(Text, MaxTopics) ->
    {ok, _} = application:ensure_all_started(inets),
    post(backend(), build_prompt(Text, MaxTopics)).

post(#{endpoint := Endpoint, model := Model, timeout := Timeout}, Prompt) ->
    Body = jsx:encode(#{
        <<"model">>       => Model,
        <<"messages">>    => [
            #{<<"role">> => <<"user">>, <<"content">> => Prompt}
        ],
        <<"max_tokens">>  => 200,
        <<"temperature">> => 0
    }),
    Headers  = [{"Content-Type", "application/json"}],
    case httpc:request(post, {binary_to_list(Endpoint), Headers, "application/json", Body},
                       [{timeout, Timeout}], []) of
        {ok, {{_, 200, _}, _RespHeaders, RespBody}} ->
            parse_response(list_to_binary(RespBody));
        {ok, {{_, Status, _}, _RespHeaders, RespBody}} ->
            {error, {api_error, Status, RespBody}};
        {error, _} = E ->
            E
    end.

build_prompt(Text, MaxTopics) ->
    iolist_to_binary(io_lib:format(?PROMPT_TEMPLATE, [MaxTopics, Text])).

parse_response(RespBody) ->
    try
        #{<<"choices">> := [#{<<"message">> := #{<<"content">> := Content}} | _]} =
            jsx:decode(RespBody, [return_maps]),
        {ok, extract_topics(Content)}
    catch
        _:_ -> {error, invalid_response}
    end.

extract_topics(Content) when is_binary(Content) ->
    JsonArray = strip_code_fence(Content),
    decode_topics(JsonArray).

decode_topics(JsonArray) ->
    case catch jsx:decode(JsonArray, [return_maps]) of
        Topics when is_list(Topics) ->
            [to_topic(T) || T <- Topics, is_valid_topic(T)];
        _ ->
            []
    end.

strip_code_fence(Bin) ->
    case binary:split(Bin, <<"```">>) of
        [_, Middle | _] -> strip_inner_fence(Middle);
        _               -> Bin
    end.

strip_inner_fence(Middle) ->
    case binary:split(Middle, <<"```">>) of
        [Inner | _] -> strip_lang_prefix(Inner);
        _           -> Middle
    end.

strip_lang_prefix(Bin) ->
    case binary:split(Bin, <<"\n">>) of
        [Line, Rest] when Line =:= <<"json">>; Line =:= <<"JSON">> -> Rest;
        _ -> Bin
    end.

to_topic(T) when is_binary(T) -> string:lowercase(string:trim(T));
to_topic(T) when is_list(T)   -> to_topic(list_to_binary(T)).

is_valid_topic(T) when is_binary(T) -> byte_size(T) > 0;
is_valid_topic(T) when is_list(T)   -> length(T) > 0;
is_valid_topic(_)                   -> false.

%%% Internal — config

topic_config() ->
    application:get_env(mcl_rag, topic_classifier, #{}).
