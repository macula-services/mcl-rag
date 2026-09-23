%%% @doc Header-aware markdown chunker.
%%%
%%% Splits a markdown file into chunks following the heading
%%% structure. Each chunk:
%%%
%%%   - belongs to a single (h1, h2, h3, h4) header path,
%%%   - is bounded to roughly `max_chars' of body text,
%%%   - is split further at paragraph boundaries when oversized,
%%%   - skips fenced code blocks at the splitting step (they are
%%%     kept whole; oversized code blocks become their own chunk).
%%%
%%% Returned chunk shape:
%%%
%%%   #{chunk_id     :: binary(),
%%%     content      :: binary(),
%%%     source_path  :: binary(),
%%%     header_path  :: binary(),
%%%     kind         :: prose | code,
%%%     start_line   :: pos_integer(),
%%%     end_line     :: pos_integer()}
%%%
%%% `chunk_id' is `sha256(source_path | header_path | start_line)'
%%% truncated to 16 hex bytes — stable across re-ingests, so
%%% re-seeding replaces an existing chunk via the
%%% `rag_store:add_chunk' upsert.
-module(markdown_chunker).

-export([chunk_file/2, chunk_text/3]).

-define(DEFAULT_MAX_CHARS, 2000).
-define(DEFAULT_MIN_CHARS,   80).

-type chunk() :: #{
    chunk_id    := binary(),
    content     := binary(),
    source_path := binary(),
    header_path := binary(),
    kind        := prose | code,
    start_line  := pos_integer(),
    end_line    := pos_integer()
}.
-export_type([chunk/0]).

-spec chunk_file(file:filename_all(), binary()) -> {ok, [chunk()]} | {error, term()}.
chunk_file(AbsPath, RelPath) ->
    case file:read_file(AbsPath) of
        {ok, Bin}      -> {ok, chunk_text(Bin, RelPath, ?DEFAULT_MAX_CHARS)};
        {error, _} = E -> E
    end.

-spec chunk_text(binary(), binary(), pos_integer()) -> [chunk()].
chunk_text(Bin, RelPath, MaxChars) ->
    Lines = binary:split(Bin, <<"\n">>, [global]),
    Numbered = lists:zip(lists:seq(1, length(Lines)), Lines),
    Sections = sectionise(Numbered, [], _Stack = [], []),
    lists:flatmap(
        fun({HeaderPath, StartLine, SectionLines, Kind}) ->
            split_section(RelPath, HeaderPath, StartLine, SectionLines, Kind, MaxChars)
        end,
        Sections
    ).

%%% Sectioniser: walk numbered lines, maintain header stack, emit one
%%% section per header break, plus code-fence sections kept whole.
%%%
%%% Sections list is built in reverse and reversed at return.

sectionise([], CurAcc, Stack, Sections) ->
    Sections1 = flush(CurAcc, Stack, Sections),
    lists:reverse(Sections1);

sectionise([{N, Line} | Rest], CurAcc, Stack, Sections) ->
    case classify(Line) of
        {header, Level, Title} ->
            Sections1 = flush(CurAcc, Stack, Sections),
            Stack1    = push_header(Stack, Level, Title),
            sectionise(Rest, [{N, Line}], Stack1, Sections1);

        code_fence_open ->
            %% Pull the code block whole, then continue.
            {CodeLines, AfterCode} = consume_code_block(Rest, [{N, Line}]),
            Sections1 = flush(CurAcc, Stack, Sections),
            Sections2 = emit(Stack, CodeLines, code, Sections1),
            sectionise(AfterCode, [], Stack, Sections2);

        text ->
            sectionise(Rest, [{N, Line} | CurAcc], Stack, Sections)
    end.

flush([], _Stack, Sections) -> Sections;
flush(Acc, Stack, Sections) -> emit(Stack, lists:reverse(Acc), prose, Sections).

emit(Stack, NumberedLines, Kind, Sections) ->
    HeaderPath = render_header_path(Stack),
    {StartLine, _} = hd(NumberedLines),
    Section = {HeaderPath, StartLine, NumberedLines, Kind},
    [Section | Sections].

%%% Header stack operations

push_header(Stack, Level, Title) ->
    %% Pop anything at or deeper than the new level, then push.
    Kept = [{L, T} || {L, T} <- Stack, L < Level],
    Kept ++ [{Level, Title}].

render_header_path([]) -> <<"">>;
render_header_path(Stack) ->
    Titles = [T || {_, T} <- Stack],
    iolist_to_binary(lists:join(<<" > ">>, Titles)).

%%% Line classifiers

classify(Line) ->
    Trim = trim_left(Line),
    case Trim of
        <<"```", _/binary>>  -> code_fence_open;
        <<"~~~", _/binary>>  -> code_fence_open;
        <<"#",  _/binary>>   -> classify_header(Trim);
        _                    -> text
    end.

classify_header(Bin) ->
    case header_level(Bin, 0) of
        {Level, Rest} when Level >= 1, Level =< 6 ->
            {header, Level, trim(Rest)};
        _ ->
            text
    end.

header_level(<<"#", Rest/binary>>, N) -> header_level(Rest, N + 1);
header_level(Rest, N) -> {N, Rest}.

%%% Code fence consumer

consume_code_block([], Acc) ->
    {lists:reverse(Acc), []};
consume_code_block([{_N, Line} = NL | Rest], Acc) ->
    case is_code_fence_close(Line) of
        true  -> {lists:reverse([NL | Acc]), Rest};
        false -> consume_code_block(Rest, [NL | Acc])
    end.

is_code_fence_close(Line) ->
    Trim = trim_left(Line),
    case Trim of
        <<"```", _/binary>> -> true;
        <<"~~~", _/binary>> -> true;
        _ -> false
    end.

%%% Splitter: render section to text and slice further if too big.

split_section(RelPath, HeaderPath, StartLine, NumberedLines, Kind, MaxChars) ->
    %% Lines are {N, Bin}. Render with newlines; carry start/end line.
    case NumberedLines of
        [] -> [];
        _  -> emit_section(RelPath, HeaderPath, StartLine, NumberedLines, Kind, MaxChars)
    end.

emit_section(RelPath, HeaderPath, StartLine, NumberedLines, Kind, MaxChars) ->
    Body = render_lines(NumberedLines),
    Sz   = byte_size(Body),
    case Sz =< MaxChars orelse Kind =:= code of
        true  -> keep_or_skip(RelPath, HeaderPath, StartLine, NumberedLines, Body, Kind, Sz);
        false -> split_paragraphs(RelPath, HeaderPath, NumberedLines, MaxChars)
    end.

%% Skip tiny scraps (lonely headers, blank lines); otherwise emit one chunk.
keep_or_skip(_RelPath, _HeaderPath, _StartLine, _NumberedLines, _Body, _Kind, Sz)
  when Sz < ?DEFAULT_MIN_CHARS ->
    [];
keep_or_skip(RelPath, HeaderPath, StartLine, NumberedLines, Body, Kind, _Sz) ->
    {EndLine, _} = lists:last(NumberedLines),
    [chunk(RelPath, HeaderPath, StartLine, EndLine, Body, Kind)].

%%% Paragraph splitter: group lines into paragraphs (blank-line
%%% separated), then pack into chunks under MaxChars.

split_paragraphs(RelPath, HeaderPath, NumberedLines, MaxChars) ->
    Paras = group_paragraphs(NumberedLines, [], []),
    pack(RelPath, HeaderPath, Paras, MaxChars, [], 0, []).

group_paragraphs([], [], Acc) -> lists:reverse(Acc);
group_paragraphs([], CurAcc, Acc) -> lists:reverse([lists:reverse(CurAcc) | Acc]);
group_paragraphs([{_, <<"">>} | Rest], [], Acc) ->
    %% Skip leading blank lines between paragraphs.
    group_paragraphs(Rest, [], Acc);
group_paragraphs([{_, <<"">>} | Rest], CurAcc, Acc) ->
    %% Blank line closes paragraph.
    group_paragraphs(Rest, [], [lists:reverse(CurAcc) | Acc]);
group_paragraphs([NL | Rest], CurAcc, Acc) ->
    group_paragraphs(Rest, [NL | CurAcc], Acc).

pack(RelPath, HeaderPath, [], _MaxChars, Buf, _BufSz, Out) ->
    Out1 = flush_buf(RelPath, HeaderPath, Buf, Out),
    lists:reverse(Out1);
pack(RelPath, HeaderPath, [Para | Rest], MaxChars, Buf, BufSz, Out) ->
    ParaText = render_lines(Para),
    ParaSz   = byte_size(ParaText),
    case BufSz + ParaSz =< MaxChars of
        true ->
            pack(RelPath, HeaderPath, Rest, MaxChars,
                 Buf ++ Para, BufSz + ParaSz + 1, Out);
        false when Buf =:= [] ->
            %% Single paragraph already bigger than MaxChars; emit it whole.
            {Start, _} = hd(Para),
            {End,   _} = lists:last(Para),
            Out1 = [chunk(RelPath, HeaderPath, Start, End, ParaText, prose) | Out],
            pack(RelPath, HeaderPath, Rest, MaxChars, [], 0, Out1);
        false ->
            Out1 = flush_buf(RelPath, HeaderPath, Buf, Out),
            pack(RelPath, HeaderPath, [Para | Rest], MaxChars, [], 0, Out1)
    end.

flush_buf(_RelPath, _HeaderPath, [], Out) -> Out;
flush_buf(RelPath, HeaderPath, Buf, Out) ->
    {Start, _} = hd(Buf),
    {End,   _} = lists:last(Buf),
    Body = render_lines(Buf),
    case byte_size(Body) < ?DEFAULT_MIN_CHARS of
        true  -> Out;
        false -> [chunk(RelPath, HeaderPath, Start, End, Body, prose) | Out]
    end.

%%% Builders

chunk(RelPath, HeaderPath, Start, End, Body, Kind) ->
    Id = chunk_id(RelPath, HeaderPath, Start),
    #{
        chunk_id    => Id,
        content     => Body,
        source_path => RelPath,
        header_path => HeaderPath,
        kind        => Kind,
        start_line  => Start,
        end_line    => End
    }.

chunk_id(RelPath, HeaderPath, Start) ->
    Bin = <<RelPath/binary, "|", HeaderPath/binary, "|",
            (integer_to_binary(Start))/binary>>,
    Hex = binary:encode_hex(crypto:hash(sha256, Bin)),
    %% 16 hex chars = 64 bits, plenty for a per-corpus identifier.
    <<Short:16/binary, _/binary>> = Hex,
    string:lowercase(Short).

render_lines(NumberedLines) ->
    iolist_to_binary(
        lists:join(<<"\n">>, [L || {_, L} <- NumberedLines])
    ).

%%% Tiny binary helpers (avoiding string: for binaries)

trim(B) -> trim_right(trim_left(B)).

trim_left(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t -> trim_left(Rest);
trim_left(B) -> B.

trim_right(B) ->
    case binary:last(B) of
        C when C =:= $\s; C =:= $\t ->
            trim_right(binary:part(B, 0, byte_size(B) - 1));
        _ -> B
    end.
