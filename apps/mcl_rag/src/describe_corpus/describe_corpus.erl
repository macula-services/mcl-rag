%%% @doc Query desk: describe_corpus. What this provider serves: every repo
%%% of its corpus list at its pinned commit, and the embedding it serves them
%%% in, named by one hash.
%%%
%%% The corpus hash and the operator's signature are the RAG service
%%% contract's (macula_rag, guides/rag_service_contract.md): this provider and
%%% every caller take them from that one definition. Every answer_query reply
%%% carries the hash. mcl-rag signs when it has an identity key: `signature' is
%%% macula_rag:sign_corpus/2 of the hash, `signed_by' the hex node id of that
%%% key, a display label and never evidence. A caller checks the whole
%%% description with macula_rag:verify_corpus/3, against the provider it pinned.
%%% Without an identity key the corpus is unsigned and neither key is present.
%%%
%%% A node with no corpus list serves only deposits: an empty corpus, still
%%% named. A list that is there and refused names nothing, and is refused here
%%% too, so it cannot pass for an empty one.
-module(describe_corpus).

-export([describe/0, corpus_hash/0]).

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
    {ok, D#{signature => macula_rag:sign_corpus(Hash, Key),
            signed_by => binary:encode_hex(NodeId, lowercase)}};
signed(_Unsigned, Described) ->
    Described.

hashed({ok, #{corpus_hash := Hash}}) -> {ok, Hash};
hashed({error, _} = E)              -> E.

listed({ok, Repos})                            -> {ok, [maps:with([id, url, branch, commit], R) || R <- Repos]};
listed({error, {config_read_failed, enoent}}) -> {ok, []};
listed({error, Reason})                        -> {error, {corpus_list_refused, Reason}}.

described({ok, Repos}, #{model := Model, dim := Dim}) when is_binary(Model) ->
    Described = #{model => Model, dim => Dim, repos => Repos},
    {ok, Described#{corpus_hash => macula_rag:corpus_hash(Described)}};
described({ok, _Repos}, #{model := undefined}) ->
    {error, no_embed_model};
described({error, _} = E, _Embedding) ->
    E.

