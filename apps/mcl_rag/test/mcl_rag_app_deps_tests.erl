%% @doc No app lists a dependency it never uses.
%%
%% An `applications' entry starts that application and puts it in the release.
%% One listed but never called is cruft that runs idle. So for each of this
%% service's apps, every non-OTP application it lists must be used by one of its
%% own modules: a module of that dependency is called (the beam's imports) or
%% implemented as a behaviour. Read from the compiled beams, not by grep.
-module(mcl_rag_app_deps_tests).

-include_lib("eunit/include/eunit.hrl").

-define(APPS, [mcl_rag, rag, embed_corpus, refresh_corpus, serve_retrieval, query_chunks, query_sources]).
%% OTP's own, whose use is often indirect (a callback module, httpc's inets).
-define(OTP, [kernel, stdlib, crypto, inets, ssl, sasl, public_key, asn1]).

every_listed_dependency_is_used_test_() ->
    [{atom_to_list(App), ?_assertEqual([], unused(App))} || App <- ?APPS].

unused(App) ->
    ok = load(App),
    {ok, Listed} = application:get_key(App, applications),
    {ok, Own} = application:get_key(App, modules),
    Used = lists:usort(lists:flatmap(fun referenced/1, Own)),
    [Dep || Dep <- Listed, not lists:member(Dep, ?OTP), not lists:member(Dep, ?APPS),
            not uses(Dep, Used)].

uses(Dep, Used) ->
    ok = load(Dep),
    {ok, Mods} = application:get_key(Dep, modules),
    lists:any(fun(M) -> lists:member(M, Used) end, Mods).

%% The modules a beam calls into, and the behaviours it implements.
referenced(Mod) ->
    {ok, {_, [{imports, Imports}, {attributes, Attrs}]}} =
        beam_lib:chunks(code:which(Mod), [imports, attributes]),
    Behaviours = proplists:get_value(behaviour, Attrs, []) ++ proplists:get_value(behavior, Attrs, []),
    [M || {M, _F, _A} <- Imports] ++ Behaviours.

load(App) ->
    case application:load(App) of
        ok -> ok;
        {error, {already_loaded, App}} -> ok
    end.
