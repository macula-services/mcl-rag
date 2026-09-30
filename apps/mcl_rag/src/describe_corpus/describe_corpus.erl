%%% @doc Query desk: describe_corpus. What this provider serves: every repo
%%% of its corpus list at its pinned commit, and the embedding it serves them
%%% in, named by one hash.
%%%
%%% corpus_hash is the lowercase hex sha256 of the RFC 8785 canonical JSON of
%%%   {"dim": Dim, "model": Model, "repos": [{"branch", "commit", "id", "url"}]}
%%% with the repos in list order. The same repos in another embedding are
%%% another corpus, which is why the model and dim are in it. Every
%%% answer_query reply carries it, so a caller can tell which corpus answered
%%% and recompute the hash from this description.
%%%
%%% THE OPERATOR'S SIGNATURE (optional in the contract; mcl-rag signs when it
%%% has an identity key). `signature' is a macula_signed_object, carrying its
%%% key, over #{corpus_hash} under the label ?LABEL; `signed_by' is the hex node
%%% id of that key. A caller verifies the object under the label and its own
%%% profile, checks the signed hash equals the described one, and checks that
%%% signed_by, derived from the carried key, is the node it called. The label
%%% keeps this signature from ever passing for any other signed object. Without
%%% an identity key the corpus is unsigned and neither key is present.
%%%
%%% A node with no corpus list serves only deposits: an empty corpus, still
%%% named. A list that is there and refused names nothing, and is refused here
%%% too, so it cannot pass for an empty one.
-module(describe_corpus).

-export([describe/0, corpus_hash/0, canonical_json/1]).

-define(LABEL, <<"macula-rag corpus v1">>).

-spec describe() -> {ok, map()} | {error, term()}.
describe() ->
    signed(identity(), unsigned()).

%% @doc The hash alone, for answer_query: nothing to sign there.
-spec corpus_hash() -> {ok, binary()} | {error, term()}.
corpus_hash() ->
    hashed(unsigned()).

unsigned() ->
    described(listed(corpus_repos_config:read()), rag_embedder:embedding()).

identity() ->
    identity_key(mcl_om:identity_key()).

identity_key({ok, Key})   -> identity_node(macula_node_keys:node_id(Key), Key);
identity_key({error, _})  -> unsigned.

identity_node({ok, NodeId}, Key) -> {Key, NodeId};
identity_node({error, _}, _Key)  -> unsigned.

signed({Key, NodeId}, {ok, #{corpus_hash := Hash} = D}) ->
    Object = macula_signed_object:sign(?LABEL, #{{text, <<"corpus_hash">>} => {text, Hash}}, Key),
    {ok, D#{signature => macula_signed_object:encode(Object),
            signed_by => binary:encode_hex(NodeId, lowercase)}};
signed(_Unsigned, Described) ->
    Described.

hashed({ok, #{corpus_hash := Hash}}) -> {ok, Hash};
hashed({error, _} = E)              -> E.

listed({ok, Repos})                            -> {ok, [maps:with([id, url, branch, commit], R) || R <- Repos]};
listed({error, {config_read_failed, enoent}}) -> {ok, []};
listed({error, Reason})                        -> {error, {corpus_list_refused, Reason}}.

described({ok, Repos}, #{model := Model, dim := Dim}) when is_binary(Model) ->
    Identity = #{<<"dim">> => Dim, <<"model">> => Model,
                 <<"repos">> => [json_keyed(R) || R <- Repos]},
    {ok, #{corpus_hash => sha256_hex(canonical_json(Identity)),
           model => Model, dim => Dim, repos => Repos}};
described({ok, _Repos}, #{model := undefined}) ->
    {error, no_embed_model};
described({error, _} = E, _Embedding) ->
    E.

json_keyed(Repo) ->
    maps:from_list([{atom_to_binary(K), V} || {K, V} <- maps:to_list(Repo)]).

%% @doc RFC 8785 canonical JSON for what a corpus identity holds: objects with
%% binary keys (sorted; all ASCII here, where code-unit order is byte order),
%% arrays, strings and integers.
-spec canonical_json(map() | list() | binary() | integer()) -> binary().
canonical_json(M) when is_map(M) ->
    Members = [[string(K), $:, canonical_json(V)] || {K, V} <- lists:sort(maps:to_list(M))],
    iolist_to_binary([${, lists:join($,, Members), $}]);
canonical_json(L) when is_list(L) ->
    iolist_to_binary([$[, lists:join($,, [canonical_json(V) || V <- L]), $]]);
canonical_json(B) when is_binary(B) ->
    string(B);
canonical_json(I) when is_integer(I) ->
    integer_to_binary(I).

string(B) ->
    iolist_to_binary([$", [escape(C) || <<C>> <= B], $"]).

escape($")  -> <<"\\\"">>;
escape($\\) -> <<"\\\\">>;
escape($\b) -> <<"\\b">>;
escape($\f) -> <<"\\f">>;
escape($\n) -> <<"\\n">>;
escape($\r) -> <<"\\r">>;
escape($\t) -> <<"\\t">>;
escape(C) when C < 16#20 -> io_lib:format("\\u~4.16.0b", [C]);
escape(C)   -> C.

sha256_hex(Bin) ->
    binary:encode_hex(crypto:hash(sha256, Bin), lowercase).
