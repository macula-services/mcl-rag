%%% @doc Query desk: get_chunk_by_id. Looks up by id from the read
%%% model (delegates to rag_store).
-module(get_chunk_by_id).

-export([handle/1]).

-spec handle(binary() | undefined) -> {ok, map()} | {error, term()}.
handle(Id) when is_binary(Id) ->
    rag_store:get(Id);
handle(_) ->
    {error, missing_id}.
