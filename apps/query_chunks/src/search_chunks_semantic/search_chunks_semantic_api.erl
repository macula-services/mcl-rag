%%% @doc Cowboy handler — GET/POST /api/rag/chunks/search.
%%%
%%% GET: query-string params (top_k arrives as a binary; coerced).
%%% POST: JSON body (top_k stays a real integer; preferred by MCP).
-module(search_chunks_semantic_api).

-export([init/2, routes/0]).

routes() -> [{"/api/rag/chunks/search", ?MODULE, []}].

init(Req0, State) ->
    Req = case cowboy_req:method(Req0) of
        <<"GET">> ->
            Params = coerce(maps:from_list(cowboy_req:parse_qs(Req0))),
            respond(search_chunks_semantic:handle(Params), Req0);
        <<"POST">> ->
            handle_post(Req0);
        _ ->
            mcl_rag_http:method_not_allowed(Req0)
    end,
    {ok, Req, State}.

handle_post(Req0) ->
    case mcl_rag_http:read_json_body(Req0) of
        {ok, Params, Req1}          -> respond(search_chunks_semantic:handle(Params), Req1);
        {error, invalid_json, Req1} -> mcl_rag_http:bad_request(<<"Invalid JSON">>, Req1)
    end.

respond({ok, Items}, Req) ->
    mcl_rag_http:ok_json(#{items => Items}, Req);
respond({error, Reason}, Req) ->
    mcl_rag_http:bad_request(iolist_to_binary(io_lib:format("~p", [Reason])), Req).

%% Cowboy returns query-string values as binaries; the underlying
%% search_chunks_semantic expects `top_k' to be an integer (it
%% falls back to default for any other shape).
coerce(#{<<"top_k">> := B} = M) when is_binary(B) ->
    M#{<<"top_k">> => binary_to_integer_or_default(B)};
coerce(M) -> M.

binary_to_integer_or_default(B) ->
    try binary_to_integer(B) catch _:_ -> 10 end.
