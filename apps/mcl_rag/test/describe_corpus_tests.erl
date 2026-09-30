%% @doc A corpus names itself: the repos it serves, each at its pinned
%% commit, and the embedding it serves them in. corpus_hash is the sha256 of
%% that, as RFC 8785 canonical JSON, so any caller can recompute it from
%% describe_corpus and compare it with the hash on every answer_query reply.
%% The vector below is the contract's own; the spec carries the same one.
-module(describe_corpus_tests).

-include_lib("eunit/include/eunit.hrl").

-define(MODEL, <<"macula/multilingual-e5-small:f16">>).
-define(A, <<"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa">>).
-define(B, <<"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb">>).
-define(VECTOR_HASH, <<"0d5f037bfa41e1bce262d87098576102063fa084f63441a348d2a7648b4b2644">>).

the_hash_is_the_contract_vector_test() ->
    with_corpus(vector_list(), fun() ->
        ?assertMatch({ok, #{corpus_hash := ?VECTOR_HASH}}, describe_corpus:describe())
    end).

the_description_carries_what_the_hash_covers_test() ->
    with_corpus(vector_list(), fun() ->
        {ok, D} = describe_corpus:describe(),
        ?assertEqual(#{corpus_hash => ?VECTOR_HASH, model => ?MODEL, dim => 384,
                       repos => [#{id => <<"alpha">>, url => <<"https://example.org/alpha.git">>,
                                   branch => <<"main">>, commit => ?A},
                                 #{id => <<"beta">>, url => <<"/srv/mirrors/beta.git">>,
                                   branch => <<"trunk">>, commit => ?B}]},
                     D)
    end).

%% The same repos in another embedding are another corpus.
the_embedding_is_part_of_the_identity_test() ->
    with_corpus(vector_list(), fun() ->
        application:set_env(mcl_rag, embed_dim, 768),
        {ok, #{corpus_hash := Other}} = describe_corpus:describe(),
        ?assertNotEqual(?VECTOR_HASH, Other)
    end).

%% A node with no corpus list serves only deposits: an empty corpus, still
%% named.
no_list_is_an_empty_corpus_test() ->
    with_path("/nonexistent/corpus-repos.json", fun() ->
        ?assertMatch({ok, #{repos := [], corpus_hash := <<_:64/binary>>}}, describe_corpus:describe())
    end).

%% A list that is there but refused names no corpus: it must not look like
%% an empty one.
a_refused_list_is_refused_test() ->
    with_corpus(#{<<"repos">> => [#{<<"id">> => <<"x">>}]}, fun() ->
        ?assertMatch({error, {corpus_list_refused, _}}, describe_corpus:describe())
    end).

%% RFC 8785: keys sorted, no whitespace, integers as they are, strings with
%% only ", \ and control characters escaped (lowercase \u00xx), everything
%% else as UTF-8.
canonical_json_test() ->
    ?assertEqual(<<"{\"a\":[1,\"x\"],\"b\":{\"c\":\"q\\\"b\\\\s\\n\\u0001", 16#c3, 16#a9, "/\"}}">>,
                 describe_corpus:canonical_json(
                     #{<<"b">> => #{<<"c">> => <<"q\"b\\s\n", 1, 16#c3, 16#a9, "/">>},
                       <<"a">> => [1, <<"x">>]})).

%%% Internals

vector_list() ->
    #{<<"repos">> => [#{<<"id">> => <<"alpha">>, <<"url">> => <<"https://example.org/alpha.git">>,
                        <<"branch">> => <<"main">>, <<"commit">> => ?A},
                      #{<<"id">> => <<"beta">>, <<"url">> => <<"/srv/mirrors/beta.git">>,
                        <<"branch">> => <<"trunk">>, <<"commit">> => ?B}]}.

with_corpus(List, Test) ->
    Path = filename:join(tmp(), "describe-corpus-" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".json"),
    ok = file:write_file(Path, jsx:encode(List)),
    try with_path(Path, Test) after file:delete(Path) end.

with_path(Path, Test) ->
    Keys = [corpus_repos_config, embed_model, embed_dim],
    Was = [{K, application:get_env(mcl_rag, K)} || K <- Keys],
    application:set_env(mcl_rag, corpus_repos_config, Path),
    application:set_env(mcl_rag, embed_model, ?MODEL),
    application:set_env(mcl_rag, embed_dim, 384),
    try Test() after [restore(K, V) || {K, V} <- Was] end.

restore(K, undefined) -> application:unset_env(mcl_rag, K);
restore(K, {ok, V})   -> application:set_env(mcl_rag, K, V).

tmp() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Dir   -> Dir
    end.
