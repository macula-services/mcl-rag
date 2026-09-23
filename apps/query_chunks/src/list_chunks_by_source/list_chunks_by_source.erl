%%% @doc Query desk: list_chunks_by_source. Every chunk recorded against a
%%% given `source_path' (delegates to rag_store).
-module(list_chunks_by_source).

-export([handle/1]).

-define(DEFAULT_LIMIT, 100).
-define(MAX_LIMIT, 500).

%% Uses mcl_om_wire:field/2, not a hard #{<<"source_path">> := ...}
%% pattern -- macula's frame decoder atomizes an inbound payload's keys
%% (binary_to_existing_atom), so a hard binary-key match here silently
%% never matches a real mesh caller's payload. See mcl_om_wire's own
%% moduledoc and hecate-corpus's antipatterns skill for the full story.
-spec handle(map()) -> {ok, [map()]} | {error, term()}.
handle(Params) when is_map(Params) ->
    handle_(mcl_om_wire:field(<<"source_path">>, Params), Params);
handle(_Params) ->
    {error, missing_source_path}.

handle_(SourcePath, Params) when is_binary(SourcePath), SourcePath =/= <<>> ->
    rag_store:list_chunks_by_source(SourcePath, limit(Params));
handle_(_SourcePath, _Params) ->
    {error, missing_source_path}.

limit(Params) ->
    case mcl_om_wire:field(<<"limit">>, Params) of
        undefined -> ?DEFAULT_LIMIT;
        L         -> min(to_pos_int(L), ?MAX_LIMIT)
    end.

%% Same as list_sources_page's: an integer on the wire (CBOR from the
%% mesh, a JSON number over HTTP) is already an integer; only text needs
%% parsing. Found live (2026-09-02): every `limit' from macula-cli was
%% silently the default.
to_pos_int(N) when is_integer(N), N > 0 -> N;
to_pos_int(Bin) when is_binary(Bin)     -> to_pos_int(catch binary_to_integer(Bin));
to_pos_int(_)                           -> ?DEFAULT_LIMIT.
