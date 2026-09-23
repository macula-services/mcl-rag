%%% @doc Query desk: list_sources_page. Returns a page of results, newest
%%% ingested first (delegates to rag_store).
-module(list_sources_page).

-export([handle/1]).

-define(DEFAULT_LIMIT, 50).
-define(MAX_LIMIT, 200).

-spec handle(map()) -> {ok, [map()]} | {error, term()}.
handle(Params) when is_map(Params) ->
    rag_store:list_sources(offset(Params), limit(Params)).

%% Uses mcl_om_wire:field/2, not hard #{<<"offset">> := ...} / <<"limit">>
%% patterns -- macula's frame decoder atomizes an inbound payload's keys
%% (binary_to_existing_atom), so a hard binary-key match here silently
%% never sees a real mesh caller's paging params. See mcl_om_wire's
%% own moduledoc and hecate-corpus's antipatterns skill for the full story.
offset(Params) ->
    case mcl_om_wire:field(<<"offset">>, Params) of
        undefined -> 0;
        O         -> to_non_neg_int(O, 0)
    end.

limit(Params) ->
    case mcl_om_wire:field(<<"limit">>, Params) of
        undefined -> ?DEFAULT_LIMIT;
        L         -> min(to_pos_int(L, ?DEFAULT_LIMIT), ?MAX_LIMIT)
    end.

to_pos_int(Bin, Default) ->
    case to_int(Bin) of
        N when is_integer(N), N > 0 -> N;
        _                            -> Default
    end.

to_non_neg_int(Bin, Default) ->
    case to_int(Bin) of
        N when is_integer(N), N >= 0 -> N;
        _                             -> Default
    end.

%% A mesh caller's `limit'/`offset' arrive as CBOR integers, an HTTP
%% caller's as JSON numbers -- integers either way; only a query-string
%% style caller sends digits as text. Found live (2026-09-02): every
%% `limit' from macula-cli was silently the default 50.
to_int(N) when is_integer(N)   -> N;
to_int(Bin) when is_binary(Bin) -> try binary_to_integer(Bin) catch _:_ -> undefined end;
to_int(_)                       -> undefined.
