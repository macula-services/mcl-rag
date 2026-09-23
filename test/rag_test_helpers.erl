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

-export([start_mcl_rag/0, stop_mcl_rag/0, write_repos_config/2, restore_env/2,
         operator_dispatch/2]).

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

%% @doc Put an mcl_rag env key back the way a test found it. Unsetting is not
%% that: an unset `data_dir' falls to the production default, which is not
%% writable here, and every later suite then fails to open the store.
-spec restore_env(atom(), {ok, term()} | undefined) -> ok.
restore_env(Key, {ok, Value}) -> application:set_env(mcl_rag, Key, Value);
restore_env(Key, undefined)   -> application:unset_env(mcl_rag, Key).

%% The node id the suites act as when they call a destructive procedure.
-define(TEST_OPERATOR, binary:copy(<<16#0F>>, 32)).

%% @doc Dispatch `Method' as a configured operator: the operator list names the
%% test node, and the payload carries it as the verified `caller' (the atom key
%% macula writes). The gate stays in the path, as it is for a real mesh call;
%% rag_operators_tests covers who is refused.
-spec operator_dispatch(binary(), map()) -> {ok, term()} | {error, term()}.
operator_dispatch(Method, Params) ->
    ok = application:set_env(mcl_rag, operators, binary:encode_hex(?TEST_OPERATOR)),
    mcl_rag_mesh_rpc:dispatch(Method, Params#{caller => ?TEST_OPERATOR}).
