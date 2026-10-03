%% @doc The chunker must not crash on lines that are only hashes (issue #2).
%% A hash-only ATX line (`#`, `###   `) has no title; it is not a heading for
%% chunking, and it must never leave the header path with an empty segment.
-module(markdown_chunker_tests).

-include_lib("eunit/include/eunit.hrl").

-define(PARA_A,
        <<"A first paragraph that is comfortably longer than the eighty-byte "
          "minimum chunk size, so it produces a chunk on its own.">>).
-define(PARA_B,
        <<"A second paragraph, also comfortably longer than the eighty-byte "
          "minimum chunk size, so it too produces a chunk.">>).

hash_only_heading_does_not_crash_test() ->
    Text = <<"# Title\n\n", ?PARA_A/binary, "\n\n#\n\n", ?PARA_B/binary, "\n">>,
    Chunks = markdown_chunker:chunk_text(Text, <<"doc.md">>, 2000),
    ?assert(length(Chunks) >= 1).

hash_only_heading_with_trailing_spaces_does_not_crash_test() ->
    Text = <<"# Title\n\n", ?PARA_A/binary, "\n\n###   \n\n", ?PARA_B/binary, "\n">>,
    Chunks = markdown_chunker:chunk_text(Text, <<"doc.md">>, 2000),
    ?assert(length(Chunks) >= 1).

hash_only_line_is_not_a_heading_test() ->
    %% No empty header-path segment: the paragraphs before and after the
    %% hash-only line stay under the last real heading.
    Text = <<"# Real\n\n", ?PARA_A/binary, "\n\n#\n\n", ?PARA_B/binary, "\n">>,
    Chunks = markdown_chunker:chunk_text(Text, <<"doc.md">>, 2000),
    Paths = lists:usort([maps:get(header_path, C) || C <- Chunks]),
    ?assertEqual([<<"Real">>], Paths).

normal_headings_still_chunk_test() ->
    Text = <<"# Title\n\n", ?PARA_A/binary, "\n\n## Sub\n\n", ?PARA_B/binary, "\n">>,
    Chunks = markdown_chunker:chunk_text(Text, <<"doc.md">>, 2000),
    Paths = lists:usort([maps:get(header_path, C) || C <- Chunks]),
    ?assertEqual([<<"Title">>, <<"Title > Sub">>], Paths).
