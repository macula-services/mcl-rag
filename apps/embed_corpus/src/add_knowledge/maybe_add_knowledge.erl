%%% @doc Handler for `add_knowledge': adds a text snippet to the index.
%%%
%%% Chunks the text (if long), embeds each chunk via `rag_chunk_embedder'
%%% (in THIS process, not inside `rag_store'), and writes each chunk
%%% with its vector. If `topics' are provided, tags each chunk after
%%% storing.
%%%
%%% Designed for conversational deposits: an agent learns something and
%%% pushes it. The server owns chunking and embedding.
-module(maybe_add_knowledge).

-export([add/1]).
%% Pure, exported for its own test coverage -- see its own doc.
-export([with_deposited_by/2]).

-define(MAX_CHUNK_CHARS, 2000).

-spec add(map()) -> {ok, #{chunks := non_neg_integer()}} | {error, term()}.
add(Params) when is_map(Params) ->
    case add_knowledge_v1:from_map(Params) of
        {ok, Cmd}      -> add_cmd(Cmd);
        {error, _} = E -> E
    end.

add_cmd(Cmd) ->
    case add_knowledge_v1:validate(Cmd) of
        ok         -> do_add(Cmd);
        {error, R} -> {error, R}
    end.

do_add(Cmd) ->
    Text = add_knowledge_v1:get_text(Cmd),
    SourceLabel = add_knowledge_v1:get_source_label(Cmd),
    Topics = add_knowledge_v1:get_topics(Cmd),
    DepositedBy = add_knowledge_v1:get_deposited_by(Cmd),
    SourcePath = label_or_default(SourceLabel),
    Chunks = with_deposited_by(chunk_text(Text, SourcePath), DepositedBy),
    {Stored, Errors} = rag_chunk_embedder:embed_and_store(Chunks),
    maybe_tag_topics(Chunks, Topics),
    log_errors(Errors),
    {ok, #{chunks => Stored}}.

%% @doc Tags every chunk with who deposited it, hex-encoded the same way
%% this module already hex-encodes chunk ids -- a raw 32-byte pubkey
%% would round-trip through barrel's JSON-shaped storage as unprintable
%% bytes, and hex is this codebase's own established convention for
%% showing a pubkey/NodeId, not a new one invented here. `undefined'
%% (no wire caller -- see `add_knowledge_v1''s own doc for when that's
%% real) tags nothing, the same way `maybe_tag_topics/2' below does
%% nothing for an absent `topics'. Exported for its own pure test
%% coverage -- the field it adds is a stored fact, worth testing without
%% an embedder or a store.
-spec with_deposited_by([map()], binary() | undefined) -> [map()].
with_deposited_by(Chunks, undefined) ->
    Chunks;
with_deposited_by(Chunks, DepositedBy) when is_binary(DepositedBy) ->
    Hex = binary:encode_hex(DepositedBy, lowercase),
    [C#{deposited_by => Hex} || C <- Chunks].

%% Chunk the text; if the chunker skips it (too short for the 80-byte
%% minimum), create a single chunk from the raw text. Conversational
%% deposits are often a paragraph or two — too short for the chunker
%% but still worth indexing.
chunk_text(Text, SourcePath) ->
    case markdown_chunker:chunk_text(Text, SourcePath, ?MAX_CHUNK_CHARS) of
        [] when byte_size(Text) > 0 ->
            [single_chunk(Text, SourcePath)];
        Chunks ->
            Chunks
    end.

single_chunk(Text, SourcePath) ->
    #{
        chunk_id => chunk_id(SourcePath, Text),
        content => Text,
        source_path => SourcePath,
        header_path => <<>>,
        kind => prose,
        start_line => 1,
        end_line => 1
    }.

chunk_id(SourcePath, Text) ->
    Bin = <<SourcePath/binary, "|", Text/binary>>,
    Hex = binary:encode_hex(crypto:hash(sha256, Bin)),
    <<Short:16/binary, _/binary>> = Hex,
    string:lowercase(Short).

maybe_tag_topics(_Chunks, undefined) -> ok;
maybe_tag_topics(_Chunks, []) -> ok;
maybe_tag_topics(Chunks, Topics) ->
    lists:foreach(fun(#{chunk_id := ChunkId}) ->
        rag_store:tag_chunk(ChunkId, Topics)
    end, Chunks).

log_errors([]) -> ok;
log_errors(Errors) ->
    lists:foreach(fun({ChunkId, Reason}) ->
        logger:warning("[add_knowledge] chunk ~s failed: ~p", [ChunkId, Reason])
    end, Errors).

label_or_default(undefined) -> <<"conversational">>;
label_or_default(<<>>) -> <<"conversational">>;
label_or_default(Label) -> Label.
