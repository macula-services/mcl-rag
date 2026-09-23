%% @doc Supervises the service's own processes: the local HTTP API, the mesh
%% RPC router the seventeen procedures go through, the corpus git sync, the
%% re-embed scheduler, and this node's place in the org's federated retrieval. The per-slice apps (rag, embed_corpus, ...) boot on
%% their own through the release.
%%
%% The HTTP API includes writes (add, upload, retire) and has no
%% authentication of its own, and the container runs on host networking, so it
%% binds LOOPBACK unless `http_ip' says otherwise. /health is mcl_om's, on its
%% own port, and is not mounted here.
-module(mcl_rag_sup).

-behaviour(supervisor).

-export([start_link/0, init/1, socket_opts/0]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 10, period => 10},
          [http_listener(),
           worker(mcl_rag_mesh_rpc),
           worker(corpus_git_sync),
           worker(refresh_corpus_scheduler),
           worker(join_federation)]}}.

worker(Module) ->
    #{id => Module,
      start => {Module, start_link, []},
      restart => permanent,
      shutdown => 5000,
      type => worker,
      modules => [Module]}.

http_listener() ->
    Dispatch = cowboy_router:compile([{'_', mcl_rag_api_routes:discover_routes()}]),
    ranch:child_spec(mcl_rag_http_listener, ranch_tcp, socket_opts(),
                     cowboy_clear, #{env => #{dispatch => Dispatch}}).

%% @doc The HTTP API's port and bind address.
-spec socket_opts() -> [{port, inet:port_number()} | {ip, inet:ip_address()}].
socket_opts() ->
    [{port, application:get_env(mcl_rag, http_port, 8451)},
     {ip, address(application:get_env(mcl_rag, http_ip, "127.0.0.1"))}].

address(Text) when is_binary(Text) -> address(binary_to_list(Text));
address(Text) ->
    {ok, Ip} = inet:parse_strict_address(Text),
    Ip.
