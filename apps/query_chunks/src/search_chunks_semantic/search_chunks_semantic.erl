%%% @doc Query desk: search_chunks_semantic.
%%%
%%% Takes a query (text OR pre-computed vector) + top_k, returns
%%% the top-k chunk hits enriched with content and source-path.
%%%
%%% Two call shapes accepted:
%%%
%%%   #{<<"query_text">> := Text, <<"top_k">> := N}
%%%       embedded as a query (rag_store:search_text, rag_embedder)
%%%
%%%   #{<<"query_vector">> := [Float], <<"top_k">> := N}
%%%       used as given. It must be the query embedding on the store's
%%%       model (e5: `query: ' plus the text, 384 dims); the service cannot
%%%       set the role of a vector it did not make. A vector of another
%%%       length is refused, `{dimension_mismatch, Expected, Got}', before
%%%       the store is touched.
%%%
%%% Both forms accept an optional `top_k` field, default 10.
%%%
%%% Optional `<<"topics">> := [binary()]` searches only the chunks
%%% tagged with any of the given topics (case-blind): the top_k best of
%%% those, however the rest of the store ranks (mcl-rag#42). It used to
%%% filter the index's answer afterwards, so tagged chunks outranked by
%%% untagged text came back short or empty.
-module(search_chunks_semantic).

-export([handle/1]).

-define(DEFAULT_TOP_K, 10).

%% Uses mcl_om_wire:field/2 throughout for PARAMS lookups (query
%% args from the wire), not hard #{<<"...">> := ...} patterns --
%% macula's frame decoder atomizes an inbound payload's keys
%% (binary_to_existing_atom), so a hard binary-key match here silently
%% never matches a real mesh caller's payload. See mcl_om_wire's own
%% moduledoc and mcl-corpus's antipatterns skill for the full story.
-spec handle(map()) -> {ok, [map()]} | {error, term()}.
handle(Params) when is_map(Params) ->
    handle_(mcl_om_wire:field(<<"query_vector">>, Params),
           mcl_om_wire:field(<<"query_text">>, Params), Params);
handle(_) ->
    {error, bad_params}.

handle_(V, _Text, Params) when is_list(V) ->
    sized(V, length(V), rag_embedder:dimension(), Params);
handle_(_V, Text, Params) when is_binary(Text) ->
    with_topics(topics(Params), fun(Topics) -> searched_text(Text, Topics, top_k(Params)) end);
handle_(_V, _Text, _Params) ->
    {error, query_text_or_vector_required}.

sized(V, Dim, Dim, Params) ->
    with_topics(topics(Params), fun(Topics) -> searched_vector(V, Topics, top_k(Params)) end);
sized(_V, Got, Expected, _Params) ->
    {error, {dimension_mismatch, Expected, Got}}.

searched_text(Text, [], TopK)     -> rag_store:search_text(Text, TopK);
searched_text(Text, Topics, TopK) -> rag_store:search_text_in_topics(Text, Topics, TopK).

searched_vector(V, [], TopK)     -> rag_store:search_vector(V, TopK);
searched_vector(V, Topics, TopK) -> rag_store:search_vector_in_topics(V, Topics, TopK).

%% The topics to search within: none (absent or empty) searches the whole
%% store. A list holding anything but strings is refused rather than widened
%% to the whole store.
topics(Params) ->
    topics_(mcl_om_wire:field(<<"topics">>, Params)).

topics_(undefined) -> {ok, []};
topics_(Topics) when is_list(Topics) ->
    case lists:all(fun is_topic/1, Topics) of
        true  -> {ok, Topics};
        false -> {error, invalid_topics}
    end;
topics_(_NotAList) ->
    {error, invalid_topics}.

is_topic(T) when is_binary(T) -> true;
is_topic(T) when is_list(T)   -> io_lib:printable_unicode_list(T);
is_topic(_)                   -> false.

with_topics({ok, Topics}, Search)  -> Search(Topics);
with_topics({error, _} = E, _Search) -> E.

top_k(Params) ->
    case mcl_om_wire:field(<<"top_k">>, Params) of
        N when is_integer(N), N > 0, N =< 100 -> N;
        _                                       -> ?DEFAULT_TOP_K
    end.
