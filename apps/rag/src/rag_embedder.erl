%%% @doc Embedding facade — the single entry point for embedding text
%%% outside of barrel's gen_server.
%%%
%%% `rag_store' used to let barrel's sync embedding policy call the
%%% embedder inline (inside the gen_server), which blocked the entire
%%% store on a 30s mesh call per chunk. This module lets callers embed
%%% text in their own process, then pass the vector to
%%% `rag_store:put_chunk_with_vector/4' or
%%% `rag_store:search_vector/2' — the gen_server only does fast writes
%%% and vector lookups, never an outbound call.
%%%
%%% Provider selection mirrors `rag_store:embedder()': `ollama' (the
%%% node's own, on loopback; msi00's since 2026-09-29) or `mcl_embedder'
%%% (over the mesh, for a node that cannot embed locally).
%%%
%%% Every text is embedded in a role: `passage' for what is stored, `query'
%%% for what is searched. The model decides what the role adds: e5 is trained
%%% on "passage: " and "query: " prefixes, and measure/e5_prefixes (2026-09-29)
%%% kept them. The scheme is keyed to the model id, not set on its own, because
%%% macula_rag merges scores between shards that name the same model and
%%% dimension: the model id must fully decide how text becomes a vector.
-module(rag_embedder).

-export([embed/2, embed_batch/2, dimension/0, embedding/0, provider/0]).

-export_type([role/0]).

-type role() :: query | passage.

%% The embedding models mcl-rag knows, and the prefix each role gets. A model
%% not listed is refused (provider/0): add it here with its scheme.
-define(SCHEMES, #{<<"macula/multilingual-e5-small:f16">> => e5}).

-spec embed(role(), binary()) -> {ok, [float()]} | {error, term()}.
embed(Role, Text) when is_binary(Text) ->
    {Module, Config} = provider(),
    Module:embed(prefixed(Role, Text), Config).

-spec embed_batch(role(), [binary()]) -> {ok, [[float()]]} | {error, term()}.
embed_batch(Role, Texts) when is_list(Texts) ->
    {Module, Config} = provider(),
    Module:embed_batch([prefixed(Role, T) || T <- Texts], Config).

prefixed(Role, Text) ->
    <<(prefix(scheme(), Role))/binary, Text/binary>>.

prefix(e5, query)   -> <<"query: ">>;
prefix(e5, passage) -> <<"passage: ">>;
prefix(none, _Role) -> <<>>.

%% No model named: only a provider module named directly (the tests' stub)
%% gets here, since ollama refuses an unnamed model. It embeds the text as is.
scheme() ->
    scheme(maps:get(model, embedding())).

scheme(undefined) -> none;
scheme(Model) ->
    case maps:find(Model, ?SCHEMES) of
        {ok, Scheme} -> Scheme;
        error -> erlang:error({unknown_embed_model, Model, maps:keys(?SCHEMES)})
    end.

-spec dimension() -> pos_integer().
dimension() ->
    application:get_env(mcl_rag, embed_dim, 384).

%% @doc The embedding the stored vectors were made with: the model's id
%% (`embed_model') and the dimension. Federated retrieval compares scores only
%% between shards that name the same one, so this must name what built the
%% store, not what would be nice. There is no default: an unnamed model is
%% refused where it is used.
-spec embedding() -> #{model := binary() | undefined, dim := pos_integer()}.
embedding() ->
    #{model => model(application:get_env(mcl_rag, embed_model, undefined)),
      dim   => dimension()}.

model(undefined) -> undefined;
model(Model)     -> to_bin(Model).

%% @doc The barrel_embed_provider module and its config, from `embed_provider':
%% `ollama' (the node's own, on loopback), `mcl_embedder' (the mesh
%% procedure, for a node that cannot embed locally), or
%% `{Module, Config}' naming any provider module directly. The one place this
%% is decided: rag_store opens barrel with the same answer, so the vectors a
%% query is embedded with always come from the provider that made the stored
%% ones.
-spec provider() -> {module(), map()}.
%% The model's prefix scheme is checked here too, so a model mcl-rag does not
%% know stops the store's open instead of the first embed.
provider() ->
    _ = scheme(),
    chosen(application:get_env(mcl_rag, embed_provider, ollama)).

chosen(mcl_embedder) ->
    {rag_embed_mcl_embedder, #{dimension => dimension()}};
chosen(ollama) ->
    Url = application:get_env(mcl_rag, embed_url, <<"http://127.0.0.1:11434">>),
    {barrel_embed_ollama, #{url => to_bin(Url), model => named(embedding())}};
chosen({Module, Config}) when is_atom(Module), is_map(Config) ->
    {Module, Config}.

%% The model the store is built with, from embedding/0: refused when unnamed,
%% never replaced by one ollama happens to have, whose vectors would not fit
%% the store's index.
named(#{model := undefined}) ->
    erlang:error({no_embed_model, "set mcl_rag's embed_model to the model the store is built with"});
named(#{model := Model}) ->
    Model.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L)   -> list_to_binary(L).
