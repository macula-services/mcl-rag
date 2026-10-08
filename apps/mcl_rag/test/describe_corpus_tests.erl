%% @doc A corpus names itself: the repos it serves, each at the branch head
%% it is served at (mcl-rag#24: the list pins nothing, the store records what
%% each repo was refreshed to), and the embedding it serves them in. corpus_hash is the sha256 of
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
    with_corpus(vector_list(), served(), fun() ->
        ?assertMatch({ok, #{corpus_hash := ?VECTOR_HASH}}, describe_corpus:describe())
    end).

the_description_carries_what_the_hash_covers_test() ->
    with_corpus(vector_list(), served(), fun() ->
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
    with_corpus(vector_list(), served(), fun() ->
        application:set_env(mcl_rag, embed_dim, 768),
        {ok, #{corpus_hash := Other}} = describe_corpus:describe(),
        ?assertNotEqual(?VECTOR_HASH, Other)
    end).

%% A repo the list names but the store does not serve yet (its first refresh
%% has not finished) is not described: no commit is claimed for it.
an_unserved_repo_is_not_described_test() ->
    with_corpus(vector_list(), #{<<"alpha">> => ?A}, fun() ->
        {ok, #{repos := Repos}} = describe_corpus:describe(),
        ?assertEqual([<<"alpha">>], [Id || #{id := Id} <- Repos])
    end).

%% Served commits are read from the store; one still opening describes
%% nothing rather than an empty corpus.
an_opening_store_is_refused_test() ->
    with_corpus(vector_list(), {error, store_opening}, fun() ->
        ?assertEqual({error, store_opening}, describe_corpus:describe())
    end).

%% A node with no corpus list serves only deposits: an empty corpus, still
%% named.
no_list_is_an_empty_corpus_test() ->
    with_path("/nonexistent/corpus-repos.json", #{}, fun() ->
        ?assertMatch({ok, #{repos := [], corpus_hash := <<_:64/binary>>}}, describe_corpus:describe())
    end).

%% A list that is there but refused names no corpus: it must not look like
%% an empty one.
a_refused_list_is_refused_test() ->
    with_corpus(#{<<"repos">> => [#{<<"id">> => <<"x">>}]}, #{}, fun() ->
        ?assertMatch({error, {corpus_list_refused, _}}, describe_corpus:describe())
    end).

%%% Internals

vector_list() ->
    #{<<"repos">> => [#{<<"id">> => <<"alpha">>, <<"url">> => <<"https://example.org/alpha.git">>,
                        <<"branch">> => <<"main">>},
                      #{<<"id">> => <<"beta">>, <<"url">> => <<"/srv/mirrors/beta.git">>,
                        <<"branch">> => <<"trunk">>}]}.

%% The heads the store serves the vector's repos at.
served() -> #{<<"alpha">> => ?A, <<"beta">> => ?B}.

with_corpus(List, Served, Test) ->
    Path = filename:join(tmp(), "describe-corpus-" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".json"),
    ok = file:write_file(Path, jsx:encode(List)),
    try with_path(Path, Served, Test) after file:delete(Path) end.

with_path(Path, Served, Test) ->
    Keys = [corpus_repos_config, embed_model, embed_dim],
    Was = [{K, application:get_env(mcl_rag, K)} || K <- Keys],
    application:set_env(mcl_rag, corpus_repos_config, Path),
    application:set_env(mcl_rag, embed_model, ?MODEL),
    application:set_env(mcl_rag, embed_dim, 384),
    ok = meck:new(rag_store, [no_link]),
    ok = meck:expect(rag_store, served_repos, fun() -> served_reply(Served) end),
    try Test()
    after
        meck:unload(rag_store),
        [restore(K, V) || {K, V} <- Was]
    end.

served_reply({error, _} = Refused) -> Refused;
served_reply(Served)               -> {ok, Served}.

restore(K, undefined) -> application:unset_env(mcl_rag, K);
restore(K, {ok, V})   -> application:set_env(mcl_rag, K, V).

tmp() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Dir   -> Dir
    end.
