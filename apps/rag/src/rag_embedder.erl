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
%%% Provider selection mirrors `rag_store:embedder()': `mcl_embedder'
%%% for fleet (over the mesh), `ollama' for dev (local HTTP).
-module(rag_embedder).

-export([embed/1, embed_batch/1, dimension/0, embedding/0, provider/0]).

-spec embed(binary()) -> {ok, [float()]} | {error, term()}.
embed(Text) when is_binary(Text) ->
    {Module, Config} = provider(),
    Module:embed(Text, Config).

-spec embed_batch([binary()]) -> {ok, [[float()]]} | {error, term()}.
embed_batch(Texts) when is_list(Texts) ->
    {Module, Config} = provider(),
    Module:embed_batch(Texts, Config).

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
%% `mcl_embedder' (the mesh procedure; production), `ollama' (a laptop), or
%% `{Module, Config}' naming any provider module directly. The one place this
%% is decided: rag_store opens barrel with the same answer, so the vectors a
%% query is embedded with always come from the provider that made the stored
%% ones.
-spec provider() -> {module(), map()}.
provider() ->
    chosen(application:get_env(mcl_rag, embed_provider, ollama)).

chosen(mcl_embedder) ->
    {rag_embed_mcl_embedder, #{dimension => dimension()}};
chosen(ollama) ->
    Url = application:get_env(mcl_rag, embed_url, <<"http://127.0.0.1:11434">>),
    Model = application:get_env(mcl_rag, embed_model, <<"nomic-embed-text">>),
    {barrel_embed_ollama, #{url => to_bin(Url), model => to_bin(Model)}};
chosen({Module, Config}) when is_atom(Module), is_map(Config) ->
    {Module, Config}.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L)   -> list_to_binary(L).
