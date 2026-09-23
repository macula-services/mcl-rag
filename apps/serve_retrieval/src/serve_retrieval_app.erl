-module(serve_retrieval_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    serve_retrieval_sup:start_link().

stop(_State) ->
    ok.
