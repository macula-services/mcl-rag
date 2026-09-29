%% @doc The corpus list pins every repo to a reviewed commit.
%%
%% corpus_git_sync ingests exactly the commit an entry names and never the
%% branch head, so what reaches answers is what a reviewed macula-fleet change
%% named. An entry with no commit, or one that is not a full 40-hex sha, refuses
%% the whole list, naming the entry: nothing then moves, and no repo quietly
%% falls back to following its branch.
-module(corpus_repos_config_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SHA, <<"7fd1a60b01f91b314f59955a4e4d4e80d8edf11d">>).

a_pinned_entry_reads_back_with_its_commit_test() ->
    with_list([entry(<<"a">>, ?SHA)], fun() ->
        ?assertMatch({ok, [#{id := <<"a">>, branch := <<"main">>, commit := ?SHA}]},
                     corpus_repos_config:read())
    end).

an_entry_without_a_commit_refuses_the_list_test() ->
    with_list([entry(<<"a">>, ?SHA), maps:remove(<<"commit">>, entry(<<"b">>, ?SHA))], fun() ->
        ?assertEqual({error, {unpinned_repo, <<"b">>}}, corpus_repos_config:read())
    end).

a_malformed_commit_refuses_the_list_test() ->
    [with_list([entry(<<"a">>, Bad)], fun() ->
         ?assertEqual({error, {malformed_commit, <<"a">>, Bad}}, corpus_repos_config:read())
     end)
     || Bad <- [<<"7fd1a60">>, <<"main">>, <<"7FD1A60B01F91B314F59955A4E4D4E80D8EDF11D">>, 42]].

an_entry_without_a_branch_refuses_the_list_test() ->
    with_list([maps:remove(<<"branch">>, entry(<<"a">>, ?SHA))], fun() ->
        ?assertEqual({error, {missing_branch, <<"a">>}}, corpus_repos_config:read())
    end).

entry(Id, Commit) ->
    #{<<"id">> => Id, <<"url">> => <<"https://github.com/x/", Id/binary, ".git">>,
      <<"branch">> => <<"main">>, <<"commit">> => Commit}.

with_list(Entries, Test) ->
    Path = filename:join(std_tmp(), "corpus-repos-" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".json"),
    ok = file:write_file(Path, jsx:encode(#{<<"repos">> => Entries})),
    Was = application:get_env(mcl_rag, corpus_repos_config),
    ok = application:set_env(mcl_rag, corpus_repos_config, Path),
    try Test()
    after
        restore(Was),
        file:delete(Path)
    end.

restore(undefined) -> application:unset_env(mcl_rag, corpus_repos_config);
restore({ok, V})   -> application:set_env(mcl_rag, corpus_repos_config, V).

std_tmp() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Dir -> Dir
    end.
