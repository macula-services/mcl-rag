%%% @doc What the corpus leaves out, so recall surfaces the paragraph that
%%% answers rather than boilerplate (mcl-rag#26).
%%%
%%%   - files: `.github/' templates, and LICENSE / LICENCE / COPYING / NOTICE
%%%     files, are not ingested at all;
%%%   - text: `%CopyrightBegin%' ... `%CopyrightEnd%' blocks and HTML comments
%%%     holding a licence or copyright header are stripped before chunking;
%%%   - chunks: one with fewer than `?MIN_LETTERS' letters once links, images,
%%%     tags and urls are taken out (a link list, a badge row, a bare heading)
%%%     is not stored.
%%%
%%% Seen live on 2026-10-08: "lesson learned by an agent while working on the
%%% fleet" returned OTP's %CopyrightBegin% headers and two PR templates as its
%%% top five hits.
-module(corpus_boilerplate).

-export([ingestible/1, stripped/1, substantive/1]).

-define(MIN_LETTERS, 20).

%% @doc Whether a corpus file, by its path relative to its repo, is ingested.
-spec ingestible(binary()) -> boolean().
ingestible(RelPath) when is_binary(RelPath) ->
    not (in_github_dir(RelPath) orelse licence_file(filename:basename(RelPath))).

in_github_dir(RelPath) ->
    lists:member(<<".github">>, filename:split(RelPath)).

licence_file(Name) ->
    re:run(Name, <<"^(licen[cs]e|copying|notice)([._-].*)?$">>, [caseless, {capture, none}]) =:= match.

%% @doc `Text' without its licence and copyright headers: every
%% `%CopyrightBegin%'..`%CopyrightEnd%' span (and the HTML comment around it),
%% and every HTML comment that holds a licence or copyright notice. Other
%% comments and the rest of the text are kept as they are.
-spec stripped(binary()) -> binary().
stripped(Text) when is_binary(Text) ->
    NoComments = re:replace(Text, <<"<!--((?:(?!-->).)*?)-->\\n?">>, fun licence_comment/2,
                            [global, dotall, {return, binary}]),
    re:replace(NoComments, <<"%CopyrightBegin%.*?%CopyrightEnd%">>, <<>>,
               [global, dotall, {return, binary}]).

licence_comment(Whole, [Inner]) ->
    case re:run(Inner, <<"%CopyrightBegin%|licensed under|license-identifier|copyright|"
                         "permission is hereby granted|general public license">>,
                [caseless, {capture, none}]) of
        match   -> <<>>;
        nomatch -> Whole
    end.

%% @doc Whether a chunk says something: at least `?MIN_LETTERS' letters once
%% markdown images and links, HTML tags and bare urls are removed.
-spec substantive(binary()) -> boolean().
substantive(Text) when is_binary(Text) ->
    Bare = lists:foldl(fun(Pattern, Acc) -> re:replace(Acc, Pattern, <<" ">>, [global, unicode, {return, binary}]) end,
                       Text,
                       [<<"!\\[[^\\]]*\\]\\([^)]*\\)">>, <<"\\[[^\\]]*\\]\\([^)]*\\)">>,
                        <<"<[^>]+>">>, <<"https?://\\S+">>]),
    Letters = re:replace(Bare, <<"\\P{L}+">>, <<>>, [global, unicode, {return, binary}]),
    string:length(Letters) >= ?MIN_LETTERS.
