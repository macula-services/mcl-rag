%%% @doc Handler for `detect_corpus_change_v1' -- real comparison, not a
%%% relay. The caller (a directory scan, typically `seed_corpus' walking
%%% a corpus tree, or an operator script) already computed `diff_hash'
%%% for a `source_path' within a `corpus_id'; this compares it against
%%% the last hash `rag_store' recorded for that exact pair
%%% (`rag_store:get_watermark/2') and only reports a real change:
%%%
%%%   - No watermark recorded yet -> a change (first time this source
%%%     has been seen under this corpus_id).
%%%   - Watermark's hash differs from the given one -> a change.
%%%   - Watermark's hash matches -> not a change; nothing written.
%%%
%%% Either way the given hash becomes the new watermark on a genuine
%%% change, so the next call compares against THIS one, not against
%%% whatever was there before -- ordinary last-write-wins, no history
%%% kept (this endpoint answers "did it change since I last checked,"
%%% not "show me every change ever").
%%%
%%% No event sourcing: same reasoning `maybe_answer_query' already gives
%%% for why a pure read isn't a fact worth persisting -- this IS a
%%% write (the watermark), but the watermark itself already IS the
%%% durable record; a separate `corpus_change_detected_v1' event would
%%% just be the same fact told twice. `changed => true | false' is
%%% returned directly so a caller (a re-embed pipeline deciding whether
%%% to bother) gets its answer in one round trip.
-module(maybe_detect_corpus_change).

-export([detect/1]).

-spec detect(map()) -> {ok, #{corpus_id := binary(), source_path := binary(), changed := boolean()}} |
                        {error, term()}.
detect(Params) when is_map(Params) ->
    case detect_corpus_change_v1:from_map(Params) of
        {ok, Cmd}      -> detect_cmd(Cmd);
        {error, _} = E -> E
    end.

detect_cmd(Cmd) ->
    case detect_corpus_change_v1:validate(Cmd) of
        ok         -> do_detect(Cmd);
        {error, R} -> {error, R}
    end.

do_detect(Cmd) ->
    %% validate/1 above already guarantees source_path/diff_hash are
    %% present -- no further defensive checks needed here.
    CorpusId = detect_corpus_change_v1:get_corpus_id(Cmd),
    SourcePath = detect_corpus_change_v1:get_source_path(Cmd),
    NewHash = detect_corpus_change_v1:get_diff_hash(Cmd),
    compare_and_record(CorpusId, SourcePath, NewHash).

compare_and_record(CorpusId, SourcePath, NewHash) ->
    record_if_changed(CorpusId, SourcePath, NewHash, changed(rag_store:get_watermark(CorpusId, SourcePath), NewHash)).

%% same hash as last time -> no change; a different (or no) prior hash -> a real change.
changed({ok, #{diff_hash := NewHash}}, NewHash) -> false;
changed({ok, #{diff_hash := _Other}}, _NewHash) -> true;
changed({error, not_found}, _NewHash)           -> true.

record_if_changed(CorpusId, SourcePath, _NewHash, false) ->
    {ok, #{corpus_id => CorpusId, source_path => SourcePath, changed => false}};
record_if_changed(CorpusId, SourcePath, NewHash, true) ->
    watermark_written(rag_store:put_watermark(CorpusId, SourcePath, NewHash), CorpusId, SourcePath).

watermark_written(ok, CorpusId, SourcePath) ->
    {ok, #{corpus_id => CorpusId, source_path => SourcePath, changed => true}};
watermark_written({error, _} = E, _CorpusId, _SourcePath) ->
    E.
