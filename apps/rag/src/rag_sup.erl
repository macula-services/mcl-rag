%%% @doc Root supervisor for the shared `rag` app.
%%%
%%% Hosts the cross-cutting infrastructure every slice depends on:
%%%   - `rag_store' — the gen_server owning the vector index +
%%%     SQLite handles
-module(rag_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children = [
        #{
            id       => rag_store,
            start    => {rag_store, start_link, []},
            restart  => permanent,
            shutdown => 5000,
            type     => worker,
            modules  => [rag_store]
        }
    ],
    {ok, {
        #{strategy => one_for_one, intensity => 10, period => 10},
        Children
    }}.
