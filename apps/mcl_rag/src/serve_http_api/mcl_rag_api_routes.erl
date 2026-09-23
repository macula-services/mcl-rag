%%% @doc Discovers Cowboy routes contributed by sibling umbrella
%%% apps under /api/v1/*. Each slice's *_api module exports a
%%% routes/0 function returning a Cowboy-style route list.
%%%
%%% This is the local admin / debug surface; production traffic
%%% comes via mesh RPC (see mcl_rag_mesh_rpc), not HTTP.
-module(mcl_rag_api_routes).

-export([discover_routes/0]).

-define(RAG_APPS, [
    rag,
    embed_corpus,
    refresh_corpus,
    serve_retrieval,
    query_chunks,
    query_sources
]).

%% @doc Walk every module in every umbrella app; collect routes/0 outputs.
%% Sort so concrete paths (e.g. `/api/rag/chunks/search`) take priority
%% over parameterised ones (`/api/rag/chunks/:chunk_id`). Cowboy
%% evaluates routes top-to-bottom.
-spec discover_routes() -> [tuple()].
discover_routes() ->
    sort_by_specificity(
        lists:flatmap(fun routes_for_app/1, ?RAG_APPS)).

sort_by_specificity(Routes) ->
    %% Fewer `:` segments = more concrete; longer path = more specific.
    Score = fun(Path) when is_list(Path) ->
        Bin = list_to_binary(Path),
        Params = length(binary:split(Bin, <<":">>, [global])) - 1,
        {Params, -byte_size(Bin)}
    end,
    lists:sort(
        fun({P1, _M1, _O1}, {P2, _M2, _O2}) ->
            Score(P1) =< Score(P2)
        end,
        Routes
    ).

%%% Internal

routes_for_app(App) ->
    case application:get_key(App, modules) of
        {ok, Modules} ->
            lists:flatmap(fun routes_for_module/1, Modules);
        undefined ->
            []
    end.

routes_for_module(Mod) ->
    %% function_exported/3 returns false for modules that haven't been
    %% loaded yet — and umbrella-app modules are typically lazy-loaded.
    %% ensure_loaded forces the BEAM file to load so the export check
    %% sees the truth.
    _ = code:ensure_loaded(Mod),
    case erlang:function_exported(Mod, routes, 0) of
        true  -> safe_routes(Mod);
        false -> []
    end.

safe_routes(Mod) ->
    try Mod:routes()
    catch _:_ -> []
    end.
