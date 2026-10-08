%% @doc What the corpus leaves out (mcl-rag#26): recall must surface the
%% paragraph that answers, not a licence header, a PR template or a chunk that
%% is only links. Seen live: "lesson learned by an agent" returned OTP's
%% %CopyrightBegin% headers and two .github PR templates as its top five.
-module(corpus_boilerplate_tests).

-include_lib("eunit/include/eunit.hrl").

templates_and_licence_files_are_not_ingested_test() ->
    [?assertNot(corpus_boilerplate:ingestible(P), P)
     || P <- [<<".github/pull_request_template.md">>, <<"docs/.github/ISSUE_TEMPLATE/bug.md">>,
              <<"LICENSE.md">>, <<"lib/LICENCE.md">>, <<"COPYING.md">>, <<"NOTICE.md">>,
              <<"license.md">>]].

ordinary_files_are_ingested_test() ->
    [?assert(corpus_boilerplate:ingestible(P), P)
     || P <- [<<"README.md">>, <<"docs/guides/licensing_your_service.md">>, <<"SECURITY.md">>,
              <<"lib/eunit/doc/guides/chapter.md">>, <<"github/notes.md">>]].

%% OTP's docs open with this block inside an HTML comment.
the_copyright_begin_block_is_stripped_test() ->
    Doc = <<"<!--\n%CopyrightBegin%\n\nSPDX-License-Identifier: Apache-2.0\n\n"
            "Copyright Ericsson AB 2023. All Rights Reserved.\n\n%CopyrightEnd%\n-->\n"
            "# EUnit\n\nA lesson about tests.\n">>,
    ?assertEqual(<<"# EUnit\n\nA lesson about tests.\n">>, corpus_boilerplate:stripped(Doc)).

a_bare_copyright_begin_block_is_stripped_test() ->
    Doc = <<"# Title\n\n%CopyrightBegin%\nCopyright 2020.\n%CopyrightEnd%\n\nBody text here.\n">>,
    ?assertEqual(<<"# Title\n\n\n\nBody text here.\n">>, corpus_boilerplate:stripped(Doc)).

%% A licence header in an HTML comment goes; an ordinary comment stays.
a_licence_comment_is_stripped_and_another_comment_kept_test() ->
    Doc = <<"<!-- Licensed under the Apache License, Version 2.0 -->\n# A\n\n<!-- TODO: link -->\ntext\n">>,
    ?assertEqual(<<"# A\n\n<!-- TODO: link -->\ntext\n">>, corpus_boilerplate:stripped(Doc)).

text_without_boilerplate_is_unchanged_test() ->
    Doc = <<"# Licensing\n\nThis service is Apache-2.0; see LICENSE.\n">>,
    ?assertEqual(Doc, corpus_boilerplate:stripped(Doc)).

%% A chunk that is only links, images, tags or punctuation answers nothing.
a_chunk_of_only_links_or_markup_has_no_substance_test() ->
    [?assertNot(corpus_boilerplate:substantive(T), T)
     || T <- [<<"- [Install](install.md)\n- [Usage](usage.md)\n- [FAQ](faq.md)\n">>,
              <<"[![CI](https://x/badge.svg)](https://x) [![Hex](https://y.svg)](https://y)\n">>,
              <<"<p align=\"center\"><img src=\"logo.png\"></p>\n">>,
              <<"---\n\n| | |\n|---|---|\n">>, <<"## See also\n">>]].

a_chunk_with_prose_has_substance_test() ->
    [?assert(corpus_boilerplate:substantive(T), T)
     || T <- [<<"A station relays sealed calls without reading them.">>,
              <<"- [Install](install.md): run the installer, then restart the node to pick it up.\n">>]].
