%%% @doc Periodic corpus git-sync for every repo named in
%%% `corpus_repos_config:read/0'. Every `?POLL_INTERVAL_MS', re-reads
%%% that config file (cheap, and it's what lets a repo being added or
%%% removed there take effect on this service's very next tick with no
%%% restart) and calls `mcl_rag_corpus_sync_nif:clone_or_sync/3' for
%%% each one -- clones it if its local path doesn't exist yet,
%%% otherwise fetches `origin' and fast-forwards. No OS `git` binary
%%% involved, on the host or in the container.
%%%
%%% Lives here (service-level infrastructure, per `mcl_rag_sup''s
%%% own module doc), not inside `refresh_corpus': it calls
%%% `mcl_rag_corpus_sync_nif', a top-level app module, and this
%%% umbrella's dependency direction runs from the top app into the
%%% sub-apps, never the reverse.
%%%
%%% Deliberately NOT coordinated with `refresh_corpus_scheduler' (the
%%% module that notices file changes and re-embeds): same
%%% "two independent, uncoordinated reconciliation loops, eventual
%%% consistency" shape the fleet's own GitOps reconciler already has.
%%% This loop's only job is
%%% keeping every configured checkout current with git; noticing that
%%% files changed and re-embedding them is `refresh_corpus_scheduler''s
%%% own separate concern, on its own separate timer, reading the same
%%% config independently.
-module(corpus_git_sync).
-behaviour(gen_server).

-export([start_link/0, sync_now/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(POLL_INTERVAL_MS, 120000).

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Force an immediate sync of every configured repo, bypassing the
%% timer. Returns one result per repo, keyed by its configured id.
-spec sync_now() -> #{binary() => term()}.
sync_now() ->
    gen_server:call(?MODULE, sync_now, infinity).

init([]) ->
    schedule_tick(0),
    {ok, #{}}.

handle_call(sync_now, _From, State) ->
    {reply, do_sync(), State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(tick, State) ->
    _ = do_sync(),
    schedule_tick(?POLL_INTERVAL_MS),
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%% Internals

schedule_tick(Delay) ->
    erlang:send_after(Delay, self(), tick).

do_sync() ->
    sync_repos(corpus_repos_config:read()).

%% A missing/invalid config file means nothing to sync -- report it,
%% don't crash the whole gen_server over it (a fresh deployment with
%% the config not mounted yet should stay up and simply do nothing
%% until it is).
sync_repos({error, Reason}) ->
    logger:warning("[corpus_git_sync] config unreadable: ~p", [Reason]),
    #{error => Reason};
sync_repos({ok, Repos}) ->
    maps:from_list([{maps:get(id, R), sync_one(R)} || R <- Repos]).

%% ensure_dir(Path) creates Path's PARENT chain, deliberately not Path
%% itself -- a fresh clone needs its own leaf directory to not already
%% exist (the standard, well-supported case for a git clone target);
%% an existing checkout's directory is already there either way.
sync_one(#{id := Id, url := Url, branch := Branch, path := Path}) ->
    ok = filelib:ensure_dir(Path),
    log_result(Id, mcl_rag_corpus_sync_nif:clone_or_sync(Url, Path, Branch)).

log_result(Id, {ok, cloned} = R) ->
    logger:info("[corpus_git_sync] ~s: cloned", [Id]),
    R;
log_result(_Id, {ok, up_to_date} = R) ->
    R;
log_result(Id, {ok, {fast_forwarded, From, To}} = R) ->
    logger:info("[corpus_git_sync] ~s: fast-forwarded ~s -> ~s", [Id, From, To]),
    R;
log_result(Id, {error, not_fast_forward} = R) ->
    logger:warning("[corpus_git_sync] ~s: local checkout has diverged from origin -- left untouched", [Id]),
    R;
log_result(Id, {error, {git_error, Msg}} = R) ->
    logger:warning("[corpus_git_sync] ~s: git error: ~ts", [Id, Msg]),
    R.
