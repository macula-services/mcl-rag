%%% @doc Cowboy handler — GET /api/rag/chunks/:chunk_id.
-module(get_chunk_by_id_api).

-export([init/2, routes/0]).

routes() -> [{"/api/rag/chunks/:chunk_id", ?MODULE, []}].

init(Req0, _State) ->
    case cowboy_req:method(Req0) of
        <<"GET">> ->
            Id = cowboy_req:binding(chunk_id, Req0),
            respond(get_chunk_by_id:handle(Id), Req0);
        _ ->
            mcl_rag_http:method_not_allowed(Req0)
    end.

respond({ok, Result}, Req0) ->
    mcl_rag_http:ok_json(Result, Req0);
respond({error, not_found}, Req0) ->
    mcl_rag_http:not_found(Req0);
respond({error, Reason}, Req0) ->
    mcl_rag_http:bad_request(iolist_to_binary(io_lib:format("~p", [Reason])), Req0).
