%% @doc Makes this node one shard of its org's federated retrieval.
%%
%% Once mcl_om's macula pool and realm exist, it configures macula_rag with
%% the org this service serves under, the realm's name, and the embedding the
%% stored vectors were made with; registers answer_federated_query as the
%% shard's responder; and publishes the shard's summary, without which no
%% query ever asks this shard. The summary's topics and bloom are empty:
%% macula_rag 0.1 carries them but asks every shard whose embedding matches,
%% and defines no bloom format to fill.
%%
%% The pool may not exist yet when the service starts, so joining waits for
%% it. A configuration macula_rag refuses (an unknown org, a realm name that
%% is not this realm's, no model named) will not fix itself, and is reported,
%% not retried.
-module(join_federation).

-behaviour(gen_server).

-export([start_link/0, start_link/1, status/0, health/0, health/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(RETRY_MS, 1000).

-type joined() :: joined | {waiting, term()} | {refused, term()}.

start_link() -> start_link(#{}).

start_link(Opts) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

%% @doc `joined', `{waiting, Why}' (the pool or realm is not there yet), or
%% `{refused, Why}' (macula_rag refused the configuration).
-spec status() -> joined().
status() -> gen_server:call(?MODULE, status).

%% @doc This shard's part of /health, from status/0 and macula_rag's own.
-spec health() -> ok | {degraded, map()} | {down, map()}.
health() -> health(status(), macula_rag:status()).

%% @doc Degraded when the org cannot reach this shard: not joined yet, or its
%% procedure's grant refused past the grace mcl_om gives its own procedures'
%% grants. Down when the configuration was refused.
-spec health(joined(), map()) -> ok | {degraded, map()} | {down, map()}.
health({refused, _} = Refused, _RagStatus) -> {down, #{federation => Refused}};
health({waiting, _} = Waiting, _RagStatus) -> {degraded, #{federation => Waiting}};
health(joined, #{responder := Responder} = RagStatus) ->
    reachable(Responder, mcl_om_provider_grant:grace_ms(), RagStatus).

reachable(granted, _Grace, _RagStatus) -> ok;
reachable({not_granted, #{since_ms := Since}}, Grace, _RagStatus) when Since < Grace -> ok;
reachable(_NotGranted, _Grace, RagStatus) -> {degraded, #{federation => RagStatus}}.

%%------------------------------------------------------------------------------
%% gen_server
%%------------------------------------------------------------------------------

init(Opts) ->
    self() ! join,
    {ok, #{joined => {waiting, not_tried}, retry_ms => maps:get(retry_ms, Opts, ?RETRY_MS)}}.

handle_call(status, _From, #{joined := Joined} = S) -> {reply, Joined, S};
handle_call(_Msg, _From, S) -> {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.

handle_info(join, S) -> {noreply, attempted(join(), S)};
handle_info(_Msg, S) -> {noreply, S}.

attempted({waiting, _} = Waiting, #{retry_ms := Ms} = S) ->
    erlang:send_after(Ms, self(), join),
    S#{joined => Waiting};
attempted(Final, S) ->
    S#{joined => Final}.

%%------------------------------------------------------------------------------
%% Joining
%%------------------------------------------------------------------------------

join() -> mesh(mcl_om:macula_client(), mcl_om:realm()).

mesh({ok, Pool}, {ok, Realm})       -> configured(macula_rag:configure(Pool, Realm, options()));
mesh({error, Why}, _Realm)          -> {waiting, Why};
mesh(_Pool, {error, Why})           -> {waiting, Why}.

configured(ok) ->
    ok = macula_rag:register_responder(fun answer_federated_query:answer/2),
    summarized(macula_rag:advertise([], <<>>));
configured({error, Why}) ->
    {refused, Why}.

summarized(ok)            -> joined;
summarized({error, Why})  -> {refused, {summary, Why}}.

options() ->
    Federation = application:get_env(mcl_rag, federation, #{}),
    #{org        => application:get_env(mcl_om, org, undefined),
      shard_id   => maps:get(shard_id, Federation, atom_to_binary(node())),
      realm_name => to_bin(maps:get(realm_name, Federation, undefined)),
      embedding  => rag_embedder:embedding()}.

to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(Other) -> Other.
