%%% @doc Shared `init_per_suite'/`end_per_suite' helper for every CT suite
%%% here. `rebar3 ct' runs every suite in one beam node, back to back:
%%% each suite's own `init_per_suite' starts the whole `mcl_rag'
%%% application (there is no per-suite isolation otherwise, since the
%%% mesh RPC/HTTP surface only exists once the real application is up),
%%% and each `end_per_suite' stops it again for the next suite.
%%%
%%% `application:stop/1' is synchronous with respect to the supervision
%%% tree terminating, but not with respect to the OS actually releasing
%%% the ranch listener's TCP port -- `gen_tcp:close' finishing does not
%%% guarantee a following `listen' on the same port succeeds immediately.
%%% Without a retry, the very next suite's own `init_per_suite' can lose
%%% that race and fail with `eaddrinuse', purely from run-to-run timing,
%%% not from anything about the code under test.
-module(rag_test_helpers).

-export([start_mcl_rag/0, stop_mcl_rag/0, write_repos_config/2]).

%% `application:stop/1' returning is not proof the OS has released the
%% ranch listener's TCP port yet -- give it a beat before the NEXT
%% suite's own `start_mcl_rag/0' tries to bind the same one.
-define(POST_STOP_SETTLE_MS, 10000).

-spec start_mcl_rag() -> ok.
start_mcl_rag() ->
    {ok, _} = application:ensure_all_started(mcl_rag),
    ok.

-spec stop_mcl_rag() -> ok.
stop_mcl_rag() ->
    _ = application:stop(mcl_rag),
    timer:sleep(?POST_STOP_SETTLE_MS),
    ok.

%% @doc Writes a `corpus_repos_config'-shaped JSON fixture at `Path'.
%% Each repo map needs `id'/`url'; `branch' is optional. Shared by any
%% suite that needs `corpus_git_sync'/`refresh_corpus_scheduler' to see
%% a specific repo list, since both read the exact same file shape.
-spec write_repos_config(file:filename_all(), [map()]) -> ok | {error, term()}.
write_repos_config(Path, Repos) ->
    Json = jsx:encode(#{<<"repos">> => [repo_json(R) || R <- Repos]}),
    file:write_file(Path, Json).

repo_json(#{id := Id, url := Url} = R) ->
    Base = #{<<"id">> => Id, <<"url">> => Url},
    add_branch(maps:get(branch, R, undefined), Base).

add_branch(undefined, Base) -> Base;
add_branch(Branch, Base)    -> Base#{<<"branch">> => Branch}.
