%%% @doc LLM-backed topic classifier.
%%%
%%% Calls an OpenAI-compatible chat completion API (Groq by default,
%%% since 2026-09-07 -- was NVIDIA NIM, persistently rate-limited
%%% fleet-wide) to classify text into
%%% 1-N topic labels. Returns a list of binary topic strings.
%%%
%%% Config (under the `mcl_rag' app env):
%%%
%%%   {topic_classifier, #{
%%%       enabled  => true | false,       %% default false
%%%       api_key  => <<"gsk_...">>,     %% <<>> = read MCL_TOPIC_API_KEY
%%%       endpoint => <<"https://api.groq.com/openai/v1/chat/completions">>,
%%%       model    => <<"openai/gpt-oss-20b">>,
%%%       timeout  => 30000,              %% ms
%%%       fallback => #{                  %% optional; defaults to DeepSeek
%%%           api_key  => <<>>,           %% <<>> = read MCL_TOPIC_FALLBACK_API_KEY
%%%           endpoint => <<"https://api.deepseek.com/v1/chat/completions">>,
%%%           model    => <<"deepseek-chat">>
%%%       }
%%%   }}
%%%
%%% THE FALLBACK. The primary and the fallback are two backends of one
%%% shape, tried in that order. A backend without a key is not in the
%%% list at all, so a node holding only the fallback's key classifies
%%% on the fallback alone, and a node holding neither is simply not
%%% configured. The switch from one to the next happens on a failure
%%% that is the backend's -- a rate limit, a 5xx, a timeout, a refused
%%% connection, a stale key -- and is logged; a 400 or 422 is the
%%% request's own fault and the same request is not sent again. NVIDIA's
%%% free endpoint answered 429 to everything for a day (2026-09-02/03),
%%% which is what this exists for -- and Groq has its own documented
%%% failure mode under multi-service load (mercury, 2026-09-02, 108x429
%%% in 2h), so this fallback path matters just as much with the new
%%% primary as it did with the old one.
%%%
%%% The API is OpenAI-compatible: POST a chat completion, receive
%%% `choices[0].message.content' containing a JSON array (possibly
%%% wrapped in a markdown code block — stripped defensively). No tool
%%% calling needed, so any working chat model is fine here.
%%%
%%% Uses `httpc' (Erlang/OTP built-in) — no external HTTP dependency.
-module(rag_topic_classifier).

-export([classify/2, classify_batch/2, configured/0, extract_topics/1]).
-export([backends/0, retryable/1]).

-define(DEFAULT_ENDPOINT, <<"https://api.groq.com/openai/v1/chat/completions">>).
-define(DEFAULT_MODEL,    <<"openai/gpt-oss-20b">>).
-define(DEFAULT_TIMEOUT,  30000).
-define(DEFAULT_MAX_TOPICS, 5).
-define(FALLBACK_ENDPOINT, <<"https://api.deepseek.com/v1/chat/completions">>).
-define(FALLBACK_MODEL,    <<"deepseek-chat">>).

-define(PROMPT_TEMPLATE,
    <<"Classify this text into 1-~B topic labels. "
      "Return ONLY a JSON array of lowercase string labels, nothing else. "
      "Be specific and concise (1-3 words per label).~n~nText: ~ts">>).

-type topic() :: binary().
-type backend() :: #{name := binary(), endpoint := binary(), model := binary(),
                     api_key := binary(), timeout := pos_integer()}.

%%% API

-spec configured() -> boolean().
configured() ->
    maps:get(enabled, topic_config(), false) =:= true andalso backends() =/= [].

%% @doc The backends that hold a key, primary first.
-spec backends() -> [backend()].
backends() ->
    Config = topic_config(),
    Primary = backend(<<"primary">>, Config, ?DEFAULT_ENDPOINT, ?DEFAULT_MODEL,
                      with_env_key(maps:get(api_key, Config, <<>>), "MCL_TOPIC_API_KEY")),
    Fallback = maps:get(fallback, Config, #{}),
    Secondary = backend(<<"fallback">>, Fallback, ?FALLBACK_ENDPOINT, ?FALLBACK_MODEL,
                        with_env_key(maps:get(api_key, Fallback, <<>>),
                                     "MCL_TOPIC_FALLBACK_API_KEY")),
    [B || #{api_key := Key} = B <- [Primary, Secondary], Key =/= <<>>].

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

%% @doc Whether a failure is the backend's rather than the request's.
-spec retryable(term()) -> boolean().
retryable({api_error, Status, _Body}) -> Status =/= 400 andalso Status =/= 422;
retryable(_Reason)                    -> true.

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
    ensure_http_apps(),
    ask(backends(), build_prompt(Text, MaxTopics), []).

ask([], _Prompt, Failures) ->
    {error, {all_backends_failed, lists:reverse(Failures)}};
ask([#{name := Name} = Backend | Rest], Prompt, Failures) ->
    case post(Backend, Prompt) of
        {ok, _Topics} = Ok -> Ok;
        {error, Reason}    -> ask_next(retryable(Reason), Rest, Backend, Prompt,
                                       [{Name, brief(Reason)} | Failures], Reason)
    end.

ask_next(false, _Rest, _Backend, _Prompt, _Failures, Reason) ->
    {error, Reason};
ask_next(true, [], _Backend, _Prompt, Failures, _Reason) ->
    ask([], undefined, Failures);
ask_next(true, [#{name := NextName, model := NextModel} | _] = Rest,
         #{name := Name, model := Model}, Prompt, Failures, Reason) ->
    logger:warning("[rag_topic_classifier] ~s (~s) failed (~s); falling back to ~s (~s)",
                   [Name, Model, brief(Reason), NextName, NextModel]),
    ask(Rest, Prompt, Failures).

post(#{endpoint := Endpoint, model := Model, api_key := ApiKey, timeout := Timeout}, Prompt) ->
    Body = jsx:encode(#{
        <<"model">>       => Model,
        <<"messages">>    => [
            #{<<"role">> => <<"user">>, <<"content">> => Prompt}
        ],
        <<"max_tokens">>  => 200,
        <<"temperature">> => 0
    }),
    Headers  = [{"Content-Type", "application/json"},
                {"Authorization", "Bearer " ++ binary_to_list(ApiKey)}],
    case httpc:request(post, {binary_to_list(Endpoint), Headers, "application/json", Body},
                       [{timeout, Timeout}], []) of
        {ok, {{_, 200, _}, _RespHeaders, RespBody}} ->
            parse_response(list_to_binary(RespBody));
        {ok, {{_, Status, _}, _RespHeaders, RespBody}} ->
            {error, {api_error, Status, RespBody}};
        {error, _} = E ->
            E
    end.

%% A reason short enough to log: a provider's error body can be a page
%% of HTML, and a 429 is the whole story.
brief({api_error, Status, _Body}) -> <<"http ", (integer_to_binary(Status))/binary>>;
brief(Reason)                     -> iolist_to_binary(io_lib:format("~0p", [Reason])).

ensure_http_apps() ->
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(ssl),
    ok.

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

backend(Name, Config, DefaultEndpoint, DefaultModel, Key) ->
    #{name     => Name,
      endpoint => maps:get(endpoint, Config, DefaultEndpoint),
      model    => maps:get(model, Config, DefaultModel),
      api_key  => Key,
      timeout  => maps:get(timeout, Config, ?DEFAULT_TIMEOUT)}.

%% An empty `api_key' in config falls back to the named environment
%% variable -- the same names sys.config.src templates in for the
%% fleet -- so no config file ever has to carry a real key.
with_env_key(<<>>, EnvVar) -> env_key(os:getenv(EnvVar));
with_env_key(Key, _EnvVar) -> Key.

env_key(false) -> <<>>;
env_key("")    -> <<>>;
env_key(Key)   -> list_to_binary(Key).
