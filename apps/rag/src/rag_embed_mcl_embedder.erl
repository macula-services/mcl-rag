%%%-------------------------------------------------------------------
%%% @doc barrel_embed provider backed by mcl-embedder over the mesh.
%%%
%%% Embedding needs an ONNX runtime (AVX2), which the boxes this service runs
%%% on may not have, so it asks the `mcl-embedder/embed' procedure instead.
%%%
%%% == Configuration ==
%%% ```
%%% Config = #{
%%%     dimension => 384,   %% mcl_embed's multilingual-e5-small
%%%     timeout   => 30000  %% mesh call timeout, ms
%%% }.
%%% '''
%%%
%%% `kind' is fixed to `raw' (no query/passage prefix), for continuity: every
%%% vector already in the store was made from raw text, and a query embedded
%%% with the model's `query:' prefix would not be comparable with them.
%%% Switching to the asymmetric prefixes would improve retrieval, but only
%%% together with re-embedding the whole store; it is a separate decision.
%%% @end
%%%-------------------------------------------------------------------
-module(rag_embed_mcl_embedder).
-behaviour(barrel_embed_provider).

-export([embed/2, embed_batch/2, dimension/1, name/0, init/1]).

-define(ORG, <<"mcl-embedder">>).
-define(PROCEDURE, <<"embed">>).
-define(DEFAULT_DIMENSION, 384).
-define(DEFAULT_TIMEOUT, 30000).

name() -> mcl_embedder.

dimension(Config) ->
    maps:get(dimension, Config, ?DEFAULT_DIMENSION).

init(Config) ->
    {ok, maps:merge(#{dimension => ?DEFAULT_DIMENSION,
                      timeout   => ?DEFAULT_TIMEOUT}, Config)}.

-spec embed(binary(), map()) -> {ok, [float()]} | {error, term()}.
embed(Text, Config) ->
    read(vector, call(#{text => Text, kind => <<"raw">>}, Config)).

-spec embed_batch([binary()], map()) -> {ok, [[float()]]} | {error, term()}.
embed_batch(Texts, Config) ->
    read(vectors, call(#{texts => Texts}, Config)).

call(Request, Config) ->
    mcl_om:call_capability(?ORG, ?PROCEDURE, Request,
                           maps:get(timeout, Config, ?DEFAULT_TIMEOUT)).

%% A reply's keys arrive as atoms only when the atom exists, otherwise as text.
read(Key, {ok, Reply}) when is_map(Reply) ->
    found(mcl_om_wire:field(Key, Reply), Reply);
read(_Key, {ok, Other}) ->
    {error, {invalid_response, Other}};
read(_Key, {error, _} = Error) ->
    Error.

found(Value, _Reply) when is_list(Value) -> {ok, Value};
found(_Missing, Reply)                   -> {error, {invalid_response, Reply}}.
