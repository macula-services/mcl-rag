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

-export([embed/1, embed_batch/1, dimension/0]).

-spec embed(binary()) -> {ok, [float()]} | {error, term()}.
embed(Text) when is_binary(Text) ->
    case provider() of
        {mcl_embedder, Config} -> rag_embed_mcl_embedder:embed(Text, Config);
        {ollama, Config}          -> barrel_embed_ollama:embed(Text, Config)
    end.

-spec embed_batch([binary()]) -> {ok, [[float()]]} | {error, term()}.
embed_batch(Texts) when is_list(Texts) ->
    case provider() of
        {mcl_embedder, Config} -> rag_embed_mcl_embedder:embed_batch(Texts, Config);
        {ollama, Config}          -> barrel_embed_ollama:embed_batch(Texts, Config)
    end.

-spec dimension() -> pos_integer().
dimension() ->
    application:get_env(mcl_rag, embed_dim, 384).

%%% Internal

provider() ->
    case application:get_env(mcl_rag, embed_provider, ollama) of
        mcl_embedder ->
            {mcl_embedder, #{dimension => dimension()}};
        ollama ->
            Url = application:get_env(mcl_rag, embed_url, <<"http://127.0.0.1:11434">>),
            Model = application:get_env(mcl_rag, embed_model, <<"nomic-embed-text">>),
            {ollama, #{url => to_bin(Url), model => to_bin(Model)}}
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L)   -> list_to_binary(L).
