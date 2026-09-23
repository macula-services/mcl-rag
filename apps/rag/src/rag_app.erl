-module(rag_app).
-behaviour(application).

-export([start/2, stop/1]).

%% Process-group scope shared across the rag umbrella — projections
%% join it to subscribe to evoq events, emitters publish to it.
-define(PG_SCOPE, rag).

start(_StartType, _StartArgs) ->
    ensure_pg_scope(?PG_SCOPE),
    rag_sup:start_link().

stop(_State) ->
    ok.

%% Idempotent. pg:start_link/1 fails with {error, {already_started, _}}
%% on subsequent calls; we treat that as success.
ensure_pg_scope(Scope) ->
    case pg:start_link(Scope) of
        {ok, _Pid}                       -> ok;
        {error, {already_started, _Pid}} -> ok
    end.
