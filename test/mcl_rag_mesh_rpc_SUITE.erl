%%% @doc Integration tests for the mesh RPC route table
%%% (mcl_rag_mesh_rpc:route/2). Exists because the barrel migration
%%% rewrote every ingest/embed/prune/answer_query handler to a plain
%%% function (ingest/1, embed/1, prune/1, retrieve/1) but the mesh route
%%% table kept calling the OLD evoq-command shape (CmdMod:from_map/1 then
%%% HandlerMod:dispatch/1, a function none of the four still export) —
%%% invisible to embed_corpus_SUITE, which calls the handlers directly and
%%% never went through this route table. A mesh caller (a plugin, a
%%% Spartan mind's rag_search tool) would have gotten `undef' on every one
%%% of these methods. This asserts the mesh path, not just the handlers.
-module(mcl_rag_mesh_rpc_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([ingest_embed_search_answer_prune_over_mesh_rpc/1,
         every_hit_says_where_it_came_from/1,
         answers_name_the_corpus_that_gave_them/1,
         unknown_method_is_rejected/1]).

all() ->
    [ingest_embed_search_answer_prune_over_mesh_rpc, every_hit_says_where_it_came_from,
     answers_name_the_corpus_that_gave_them, unknown_method_is_rejected].

init_per_suite(Config) ->
    ok = rag_test_helpers:start_mcl_rag(),
    Config.

end_per_suite(_Config) ->
    rag_test_helpers:stop_mcl_rag().

ingest_embed_search_answer_prune_over_mesh_rpc(_Config) ->
    DocId = fresh_id(),
    SourcePath = <<"capybara-", DocId/binary, ".md">>,
    Content = <<"# The Capybara\n\nCapybaras are the largest living "
                "rodents, native to South America.\n">>,

    %% Every reply through dispatch/2 is the MESH shape: each string in
    %% it is `{text, Bin}'-tagged at the boundary (mcl_rag_mesh_rpc's
    %% own moduledoc says why) -- so a bare-binary match here would be
    %% asserting the HTTP shape against the mesh route.
    {ok, #{document_id := {text, DocId}}} =
        rag_test_helpers:operator_dispatch(<<"mcl-rag.ingest_document">>, #{
            <<"document_id">> => DocId, <<"source_path">> => SourcePath,
            <<"source_type">> => <<"text/markdown">>, <<"raw_bytes">> => Content
        }),

    {ok, #{chunks := N}} =
        rag_test_helpers:operator_dispatch(<<"mcl-rag.embed_document">>,
                                      #{<<"document_id">> => DocId}),
    ?assert(N > 0),

    %% The suites' embedder hashes text, so it cannot rank a query against a
    %% passage (and e5 embeds the two differently on purpose). The route is
    %% proven with the chunk's own stored vector, which must come back first;
    %% a text query must still be answered through the same route.
    {ok, [#{content := Stored} | _]} = rag_store:list_chunks_by_source(SourcePath, 10),
    {ok, Vector} = rag_embedder:embed(passage, Stored),
    {ok, _} = mcl_rag_mesh_rpc:dispatch(<<"mcl-rag.search_chunks_semantic">>,
                                        #{<<"query_text">> => <<"largest rodent">>,
                                          <<"top_k">> => 5}),
    {ok, Hits} = mcl_rag_mesh_rpc:dispatch(<<"mcl-rag.search_chunks_semantic">>,
                                               #{<<"query_vector">> => Vector,
                                                 <<"top_k">> => 5}),
    ?assert(hit_from_source(Hits, SourcePath)),
    %% ...and a hit's content reaches the wire as tagged, non-empty text.
    ?assertMatch([#{content := {text, <<_, _/binary>>}} | _],
                 [H || #{source_path := SP} = H <- Hits, SP =:= {text, SourcePath}]),

    {ok, #{hits := AnswerHits}} =
        mcl_rag_mesh_rpc:dispatch(<<"mcl-rag.answer_query">>,
                                      #{<<"query_vector">> => Vector, <<"top_k">> => 5}),
    ?assert(hit_from_source(AnswerHits, SourcePath)),

    {ok, _} = rag_test_helpers:operator_dispatch(<<"mcl-rag.prune_chunks">>,
                                            #{<<"document_id">> => DocId}),
    {ok, GoneHits} = mcl_rag_mesh_rpc:dispatch(<<"mcl-rag.search_chunks_semantic">>,
                                                   #{<<"query_vector">> => Vector,
                                                     <<"top_k">> => 5}),
    ?assertNot(hit_from_source(GoneHits, SourcePath)).

%% THE CONTRACT'S PROVENANCE: a corpus chunk names its repo, path, commit and
%% lines and the hash of its own text, on a search hit, a chunk fetched by id
%% and a federated hit; a deposit names who deposited it.
every_hit_says_where_it_came_from(_Config) ->
    Id = fresh_id(),
    RepoId = <<"prov-repo-", Id/binary>>,
    DocId = <<RepoId/binary, "/guide.md">>,
    Commit = binary:copy(<<"c">>, 40),
    Content = <<"# The Pangolin\n\nPangolins are scaly anteaters that roll into a "
                "ball when threatened, found across Africa and Asia.\n">>,
    ok = rag_store:upsert_source(#{document_id => DocId, source_path => DocId,
                                   source_type => <<"markdown">>, raw_bytes => Content,
                                   repo_id => RepoId, commit => Commit}),
    {ok, _} = rag_test_helpers:operator_dispatch(<<"mcl-rag.embed_document">>,
                                                 #{<<"document_id">> => DocId}),
    {ok, [#{chunk_id := ChunkId, content := Stored} | _]} = rag_store:list_chunks_by_source(DocId, 10),
    StoredSha = sha(Stored),
    {ok, Vector} = rag_embedder:embed(passage, Stored),

    {ok, #{hits := Hits}} = mcl_rag_mesh_rpc:dispatch(<<"mcl-rag.answer_query">>,
                                                      #{<<"query_vector">> => Vector, <<"top_k">> => 5}),
    [#{provenance := P} | _] = [H || #{chunk_id := {text, C}} = H <- Hits, C =:= ChunkId],
    ?assertMatch(#{kind := {text, <<"corpus">>}, repo_id := {text, RepoId}, path := {text, DocId},
                   commit := {text, Commit}, content_sha256 := {text, StoredSha},
                   start_line := L, end_line := E} when is_integer(L) andalso is_integer(E), P),

    {ok, #{provenance := ByIdP}} = mcl_rag_mesh_rpc:dispatch(<<"mcl-rag.get_chunk_by_id">>,
                                                            #{<<"chunk_id">> => ChunkId}),
    ?assertEqual(P, ByIdP),

    %% A federated peer gets the same provenance on every hit (the suites'
    %% embedder cannot rank a query against a passage, so which hits come back
    %% is not the point here).
    {ok, #{shard_hits := [_ | _] = FedHits}} = federated(Stored),
    [?assertMatch(#{provenance := #{kind := _, path := _, content_sha256 := <<_:64/binary>>}}, H)
     || H <- FedHits],

    Depositor = binary:copy(<<16#5A>>, 32),
    Note = <<"The pangolin's scales are made of keratin, like human fingernails.">>,
    {ok, _} = mcl_rag_mesh_rpc:dispatch(<<"mcl-rag.add_knowledge">>,
                                        #{<<"text">> => Note, caller => Depositor}),
    {ok, NoteVector} = rag_embedder:embed(passage, Note),
    {ok, #{hits := NoteHits}} = mcl_rag_mesh_rpc:dispatch(<<"mcl-rag.answer_query">>,
                                                          #{<<"query_vector">> => NoteVector,
                                                            <<"top_k">> => 1}),
    DepositorHex = binary:encode_hex(Depositor, lowercase),
    NoteSha = sha(Note),
    ?assertMatch([#{provenance := #{kind := {text, <<"deposit">>},
                                    deposited_by := {text, DepositorHex},
                                    content_sha256 := {text, NoteSha}}}],
                 NoteHits).

%% Every answer names the corpus it came from, as describe_corpus names it.
answers_name_the_corpus_that_gave_them(_Config) ->
    {ok, #{corpus_hash := Hash, model := _, dim := 384, repos := _}} =
        mcl_rag_mesh_rpc:dispatch(<<"mcl-rag.describe_corpus">>, #{}),
    {ok, #{corpus_hash := Answered}} =
        mcl_rag_mesh_rpc:dispatch(<<"mcl-rag.answer_query">>, #{<<"query_text">> => <<"anything">>}),
    ?assertEqual(Hash, Answered).

unknown_method_is_rejected(_Config) ->
    ?assertEqual({error, {unknown_method, <<"mcl-rag.nonsense">>}},
                 mcl_rag_mesh_rpc:dispatch(<<"mcl-rag.nonsense">>, #{})).

%%% Internals

%% Mesh shape: `source_path' arrives `{text, _}'-tagged (see the test above).
hit_from_source(Hits, SourcePath) ->
    lists:any(fun(#{source_path := SP}) -> SP =:= {text, SourcePath} end, Hits).

sha(Bin) -> binary:encode_hex(crypto:hash(sha256, Bin), lowercase).

%% The shard's own answer, as a federated peer receives it (before the wire).
federated(Text) ->
    {ok, Hits} = answer_federated_query:answer(#{<<"text">> => Text}, #{top_k => 5}),
    {ok, #{shard_hits => Hits}}.

fresh_id() ->
    integer_to_binary(erlang:unique_integer([positive, monotonic])).
