%%% @doc Cowboy handler — POST /api/rag/seed.
%%%
%%% Body (JSON):
%%%
%%%   {
%%%     "seed_id":       "agents-v1",
%%%     "root_dir":      "/corpus",
%%%     "glob":          "**/*.md",
%%%     "exclude_globs": ["_build/", "priv/", "/assets/"],
%%%     "sync":          true
%%%   }
%%%
%%% `sync` defaults to false. When true, the request blocks until
%%% the ingest finishes and returns 200 with the stats map. When
%%% false, returns 202 with `{status: accepted, job_pid}` and the
%%% work happens in a spawned process; tail the service log to
%%% follow progress.
-module(seed_corpus_api).

-export([init/2, routes/0]).

routes() -> [{"/api/rag/seed", ?MODULE, []}].

init(Req0, State) ->
    Req = case cowboy_req:method(Req0) of
        <<"POST">> -> handle(Req0);
        _          -> mcl_rag_http:method_not_allowed(Req0)
    end,
    {ok, Req, State}.

handle(Req0) ->
    case mcl_rag_http:read_json_body(Req0) of
        {ok, Params, Req1} ->
            Sync = maps:get(<<"sync">>, Params, false),
            run(Sync, Params, Req1);
        {error, invalid_json, Req1} ->
            mcl_rag_http:bad_request(<<"Invalid JSON">>, Req1)
    end.

run(true, Params, Req) ->
    case maybe_seed_corpus:seed(Params) of
        {ok, Stats}    -> mcl_rag_http:ok_json(Stats, Req);
        {error, Reason} -> mcl_rag_http:bad_request(reason_to_bin(Reason), Req)
    end;
run(_False, Params, Req) ->
    case maybe_seed_corpus:seed_async(Params) of
        {ok, #{job_pid := Pid}} ->
            mcl_rag_http:ok_json(
                #{status => accepted, job_pid => list_to_binary(pid_to_list(Pid))},
                Req);
        {error, Reason} ->
            mcl_rag_http:bad_request(reason_to_bin(Reason), Req)
    end.

reason_to_bin(R) when is_atom(R)   -> atom_to_binary(R, utf8);
reason_to_bin(R) when is_binary(R) -> R;
reason_to_bin(R)                   -> iolist_to_binary(io_lib:format("~p", [R])).
