-module(refresh_corpus_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% refresh_corpus_scheduler moved to the top-level mcl_rag_sup --
%% see that module's own doc comment for why (it calls the top-level
%% corpus_repos_config module, and this umbrella's dependency
%% direction runs from the top app into the sub-apps, not back).
init([]) ->
    {ok, {
        #{strategy => one_for_one, intensity => 10, period => 10},
        []
    }}.
