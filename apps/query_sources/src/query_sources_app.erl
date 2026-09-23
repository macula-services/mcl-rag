-module(query_sources_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    query_sources_sup:start_link().

stop(_State) ->
    ok.
