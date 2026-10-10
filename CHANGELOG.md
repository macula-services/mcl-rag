# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **A corpus entry can bound its history and its paths** (mcl-rag#5). `depth` bounds the first
  clone's fetch to that many commits, a shallow checkout: kicad's `.git` drops from 4.3 GB to
  288 MB at depth 1 and zephyr's from 1.0 GB to 142 MB, and the refresh reads only the worktree
  at the head. `paths` materialises and ingests only the listed prefixes: kicad ingests 0.9 MB
  of markdown out of a 5.7 GB tree. Both are optional; absent means full history and the whole
  tree. `depth` applies at the first clone (delete a checkout to pick it up); `paths` on every
  sync. Neither is a partial clone: the fetch still brings the branch's objects (bound it with
  `depth`), and `paths` shields the disk and the walk. The measurements are in
  [Run your own corpus](docs/RUN_YOUR_OWN_CORPUS.md#2-what-the-service-does-with-it).

### Fixed

- **Paging past barrel's per-call chunk cap** (#9). One `find/3` call answers at most one chunk (1,000 rows) and
  hands the rest to `has_more`/`continuation`; the store read only that first chunk, so on a corpus over 1,000
  sources every page at `offset >= 1000` came back empty and "how far is ingestion" could not be counted
  through the public procedure. `list_sources_page` walks the cursor now, dropping the offset across chunks.

## [0.7.2] - 2026-10-10

### Changed

- **Rebuilt on macula ~> 14 (newest release):** request admission frees the slot when the reply is sent, and caller attribution covers every payload shape (macula#89, macula#60).

## [0.7.1] - 2026-10-08

### Fixed

- **A restart no longer leaves the corpus unnamed for two hours** (#27). A repo the boot refresh reached while
  the store was still opening was passed over in silence until the next tick, 2 hours later; it is logged now,
  and the refresh is retried a minute later.

## [0.7.0] - 2026-10-08

### Changed

- **The corpus follows branch heads; nothing is pinned** (#24). The corpus list is `{id, url, branch}`;
  a list that still names a `commit` is refused (`unknown_key`). Every 2 hours the node fetches each branch,
  checks out its head and, when it moved, re-ingests changed files at that head. A hit names the commit its
  text is present at (the head it was ingested at, or a later head the file was found unchanged at), and
  `describe_corpus` names each repo at the head it is served at, leaving out a repo not served yet. One loop
  (`refresh_corpus_scheduler`) replaces the separate git-sync loop; the NIF's `sync_to_head/3` replaces
  `sync_to_commit/4`.
- **Stale chunks are pruned** (#25). A changed file's old chunks are dropped before it is re-ingested (chunk ids
  are position-derived, so a reshaped file used to keep chunks of positions it no longer has); a file that is
  gone loses its chunks, source and watermark; a repo that leaves the list loses everything it stored. The new
  index generation re-ingests the corpus once and sweeps every chunk no current file leads to.
- **Recall surfaces answers, not boilerplate** (#26). `.github/` templates and LICENSE / LICENCE / COPYING /
  NOTICE files are not ingested; `%CopyrightBegin%` blocks and licence comments are stripped before chunking;
  corpus chunks that are only links or markup are not stored. Identical text is returned once per query,
  naming the other sources under `also_in`, and a query still gets `top_k` distinct hits.
- `list_chunks_by_source` returns chunks only (a file's source, watermark and re-embed requests no longer
  take slots of its limit).
- `measure/recall_quality/`: a fixed 5-query set and a script counting boilerplate, duplicate and stale hits
  on a live node, kept as a regression check.

## [0.6.1] - 2026-10-08

### Changed

- **The federated shard procedure refuses clear calls too.** On macula_rag 0.5 (`~> 0.5`), mcl-rag configures
  `rag.query_shard_v1` as `confidential => required`, so a peer shard's query is sealed or refused, like every
  other mcl-rag procedure since 0.6.0. (#16)

## [0.6.0] - 2026-10-08

### Changed

- **Clear calls are now refused.** All eighteen procedures are `confidential => required`: a caller must seal to
  the advertised ML-KEM key, and a call in the clear is refused instead of answered, so no query, deposit or
  operator write crosses a station as plaintext. Callers on macula-mcp and macula-cli seal already; an older client
  that cannot seal is refused. mcl_om's own `info` and `get_limits`, and macula_rag's `rag.query_shard_v1`, stay
  keyed but still answer a clear call. (#16)

## [0.5.0] - 2026-10-08

### Changed

- **Sealed: every procedure names its KEM key** (`{macula, [{kem_advertise, enabled}]}`, `confidential =>
  preferred` on all eighteen). A caller that can seal, such as macula-mcp's `mesh_recall` and `mesh_remember`,
  seals its query or deposit to the provider's ML-KEM key, so a station on the path relays only ciphertext. The
  federated `rag.query_shard_v1` is keyed by the same switch. A caller that cannot seal is still answered. (#16)

## [0.4.0] - 2026-10-07

### Changed

- **`/health` is served on a Unix socket only** (`/run/mcl/health.sock`, mcl_om 0.39 `health_socket`). No TCP
  health listener runs and no health port is bound on the host: `MCL_HEALTH_PORT`, the `health_port` setting and
  its `EXPOSE` are gone. The image creates `/run/mcl` and probes the socket; `scripts/health.sh` asks it through
  the container engine. A deploy that probed the port must probe the socket.

- **On mcl_om 0.39, macula 14.2 and macula_rag 0.4** (`~> 0.39`, `~> 14.2`, `~> 0.4`, released versions only),
  the SDK base every deployed service runs on; it was on mcl_om 0.33 and macula 13.0.1. The test config names an
  `identity_dir` in place of macula 14's removed `node_identity_path`, and the info test's floors follow. The
  corpus contract, provenance and the operator signature are as before. (#15)

## [0.3.4] - 2026-10-03

### Fixed

- **A corpus file that is not valid UTF-8 no longer fails its embed forever**
  ([#10](https://github.com/macula-services/mcl-rag/issues/10)): rt-thread's
  GBK/Latin-1 READMEs raised `{invalid_byte, _}` in the JSON encoder on the
  way to the embedder. #3's containment kept the scan alive, but the file
  retried and failed every tick, so it never ingested. Corpus content is read
  through a lossy UTF-8 sanitiser now (invalid or truncated bytes become
  U+FFFD), so the file ingests with replacement characters.

## [0.3.3] - 2026-10-03

### Fixed

- **`mcl-rag/info` and `/health` report the release version from the
  application's own vsn, not a hand-bumped literal.** v0.3.2 moved the image
  and rebar release to 0.3.2 but shipped the old `0.3.1` literal, so the
  deployed service named the wrong version. The eunit suite pinned the
  disagreement (`info_version_matches_the_application_test`) and
  `lint-and-test` failed on main — but `build-and-push` does not gate on
  tests yet ([#6](https://github.com/macula-services/mcl-rag/issues/6)) and
  promoted `:latest` anyway. There is one place to bump now.

## [0.3.2] - 2026-10-03

### Fixed

- **A hash-only ATX heading line crashed the chunker and stalled the corpus
  refresh** ([#2](https://github.com/macula-services/mcl-rag/issues/2)):
  `classify_header/1` trimmed the remainder, and `trim_right/1` called
  `binary:last(<<>>)`. Seen live on msi00 after the corpus grew to 52 repos:
  `refresh_corpus_scheduler` died on every tick at the first such file (9 in
  the corpus), and 3,184 of 4,028 sources never embedded. `trim_right/1` now
  accepts an empty binary, and a hash-only line classifies as text, so it
  keeps its surrounding section instead of creating an empty header-path
  segment.
- **One crashing file no longer aborts the whole scan**
  ([#3](https://github.com/macula-services/mcl-rag/issues/3)): the refresh
  loop handled `{error, _}` returns, but an exception killed the gen_server
  and the tick, leaving every later file unrefreshed until the next restart.
  Each file's refresh is now contained: the crash is logged with its path,
  the file's watermark is reset, and the scan continues.

## [0.3.1] - 2026-10-01

### Changed

- The corpus hash and the operator's signature come from macula_rag 0.3
  (`~> 0.3`, the RAG service contract), not from this service's own copy of
  the canonical JSON: the provider and every caller use one definition, held
  to that library's frozen vectors. The hash and signatures are unchanged.

## [0.3.0] - 2026-09-30

### Added

- `describe_corpus` is signed by the operator's node: `signature` (a
  macula_signed_object over `{corpus_hash}` under the label
  `macula-rag corpus v1`, carrying its key; bytes on the wire) and
  `signed_by` (the hex node id of that key). A node with no identity key
  describes an unsigned corpus, without either field.

## [0.2.0] - 2026-09-30

### Added

- **Provenance on everything returned.** Search hits (`answer_query`,
  `search_chunks_semantic`), `get_chunk_by_id`, `list_chunks_by_source`,
  source rows, `get_document_verbatim` and federated hits carry
  `provenance`: `kind` (`corpus` | `deposit`), `path`, `content_sha256`, and
  `repo_id` + `commit` for corpus content, the lines for a chunk,
  `deposited_by` for a known depositor. The corpus refresh records the repo
  and the pinned commit on each source, and every chunk write stamps the
  sha256 of its text.
- **`describe_corpus`** (open): `corpus_hash`, `model`, `dim` and the pinned
  `repos`. The realm must grant it (D25) before it is advertised.
- **`answer_query` names its corpus**: the reply is `{corpus_hash, hits}`.

### Changed

- The refresh's index generation is `provenance-v2`: on first start every
  corpus file re-ingests once, with provenance. Deposits made before 0.2.0
  carry none; msi00 starts on a fresh data volume, so there are none there.
- A hit's `meta` no longer repeats the provenance fields.

## [0.1.6] - 2026-09-30

### Added

- `MCL_RAG_CORPUS_REPOS` names the corpus list; the app env
  `corpus_repos_config` and then `/etc/mcl-rag/corpus-repos.json` follow.
- `schema/corpus-repos.schema.json` (JSON Schema 2020-12) publishes the list's
  rules, and a test holds it to the ones the service enforces.
- `docs/RUN_YOUR_OWN_CORPUS.md`: serving a corpus of your own.

### Changed

- The corpus list is refused, naming the entry, for an id that is not
  lowercase letters, digits and dashes (`malformed_id`: the id names the
  checkout directory, so `../x` could have left it), a duplicate id
  (`duplicate_id`), a url that is neither `https://` nor an absolute path
  (`unsupported_url`), or a key outside id, url, branch and commit
  (`unknown_key`). The shipped list and msi00's already meet all four.

## [0.1.5] - 2026-09-30

### Fixed

- A supplied `query_vector` of the wrong length is refused with
  `{dimension_mismatch, Expected, Got}` (`search_chunks_semantic`,
  `answer_query`), before the store is touched. It used to be searched as
  given against the store's 384-dim vectors.
- The store takes its dimension from the embedder (`rag_embedder:dimension/0`,
  default 384). Its own default was 768, which disagreed with the embedder
  whenever `embed_dim` was unset; msi00 sets it, so it never ran that way.

## [0.1.4] - 2026-09-30

### Fixed

- `:latest` is the signed release image. 0.1.3's promote step wrapped the
  signed manifest in a new, unsigned index, so `:latest` named a digest no
  signature covers; the step now copies the manifest as it is and fails unless
  `:latest` resolves to the signed digest. No code change from 0.1.3.

## [0.1.3] - 2026-09-30

### Changed

- The corpus is pinned. Every entry in `deploy/corpus-repos.json` carries a
  40-hex `commit` on its `branch`; the node fetches the branch and checks out
  that commit detached, so a push to a corpus repo reaches the store only when
  the list moves its pin. A commit that is not on the branch is refused
  (`commit_not_on_branch`), and so is an entry with no commit or a malformed
  one, by name. The 14 shipped repos are pinned to their heads of 2026-09-30.
- CI runs the corpus-sync NIF's Rust tests (`cargo test --locked`).

## [0.1.2] - 2026-09-29

### Fixed

- The service starts. On mcl_om 0.33.2, `mcl_om_capabilities:register/1`
  advertised every procedure over the network inside a 5 s `gen_server:call`;
  mcl-rag's eighteen (its seventeen plus mcl_om's `info`) outran it, and 0.1.1 failed in `start/2` on every boot
  on msi00. mcl_om 0.33.3 replies at once and advertises after, and mcl-rag
  requires it (`~> 0.33.3`).

## [0.1.1] - 2026-09-29

### Changed

- Text is embedded in a role, with the prefix e5 is trained on: `passage: `
  for everything stored (add, upload, embed, seed, the corpus
  refresh) and `query: ` for every search (`answer_query`,
  `search_chunks_semantic`, the federated shard answer). The pre-registered
  measurement in `measure/e5_prefixes` kept them (recall@5 tied at 1.0,
  MRR@10 0.9167 against 0.9083 raw: one query's rank). 0.1.0 was never
  deployed, so mcl-rag stored no vector without them. A store carried over
  from `hecate-rag` (0.1.0's "opens as it is") holds raw-text vectors: it
  still opens, but every search would compare a `query: ` vector with them.
  Such a store must be re-embedded: start on an empty data volume and the
  node re-embeds the corpus (deposits made in it are lost).
- A supplied `query_vector` (`search_chunks_semantic`, `answer_query`) must
  be the query embedding on the store's model: `query: ` plus the text,
  through `macula/multilingual-e5-small:f16`, 384 dims. The service cannot
  set the role of a vector it did not make.
- The prefix scheme is keyed to the embed model id in `rag_embedder`, not a
  setting: macula_rag merges scores between shards naming the same model and
  dimension, so the model id decides how text becomes a vector. A model
  mcl-rag has no scheme for is refused when the store opens.
- `rag_embedder:embed/1` and `embed_batch/1` are `embed/2` and
  `embed_batch/2`, taking the role (`query` or `passage`) first.

## [0.1.0] - 2026-09-29

### Added

- The port of `hecate-rag` onto `mcl_om` and macula: the same barrel store
  (`rag_chunks`), the same corpus, the same seventeen procedures, now served
  as `mcl-rag/<name>` under the org `mcl-rag`. A store written by `hecate-rag`
  opens as it is. The embedding policy differs only in the embedder module's
  name, and barrel logs that once on the first open.
- Operator-only procedures. The eight that delete, replace or rewrite stored
  data refuse any caller whose macula-verified node id is not in
  `MCL_RAG_OPERATORS`. In `hecate-rag` all seventeen were open.
- The store opens at start in the background. Until it is open, calls are
  refused with `store_opening` and `/health` reports `degraded`.
- Federated retrieval: the node joins the org's `macula_rag` federation as
  one shard.
- `deploy/corpus-repos.json`, the corpus list, shipped with the service and
  mounted read-only.
- `deploy/docker-compose.yml` carries the service's run contract: the realm
  name, the operators, a named data volume and the corpus list, with the image
  by digest. An eunit suite holds the Containerfile, compose and the templated
  configs to each other.
- The C4 model (context, containers, components) in `architecture/`, with its
  diagrams in `assets/`.
- `measure/e5_prefixes/`: a pre-registered measurement of whether e5's
  `query: ` / `passage: ` prefixes help retrieval on the msi00 model (corpus,
  queries, k and rule fixed before any result).

### Changed

- **On mcl_om 0.33.1, macula 13.0.1 and macula_rag 0.2** (evoq `~> 1.26.1`).
  The floors are mcl_om 0.33's own, and macula_rag 0.2 is its release on
  macula 13 (0.1 pinned macula 12). The service answers `mcl-rag/info` with no
  code of its own, and `mcl_rag_info_tests` round-trips it through macula's
  codec, checking both floors to the patch release.
- **The service requires the mesh** (`{mesh, required}`): a boot missing
  `MCL_REALM`, `MCL_REALM_KEY`, `MACULA_STATION_SEEDS` or
  `MACULA_STATION_NODE_IDS` stops and names each one.
- **Models on the node's own ollama, no key** (Raf, 2026-09-29). Embeddings
  come from ollama on loopback (`embed_provider ollama`), model
  `macula/multilingual-e5-small:f16`, built on msi00 from intfloat's own
  weights, 384 dimensions. An unnamed model is refused at start, never
  replaced by one ollama happens to have. The topic classifier asks the same
  ollama's OpenAI-compatible endpoint, `qwen2.5:7b-instruct-q4_K_M`. The Groq
  primary, the DeepSeek fallback and both API keys are removed from the code
  and the config: `rag_topic_classifier` has one backend, sends no
  credentials, and returns a failure as it is.
- **The image is signed.** build-push hands the pushed digest to
  macula-ci-images' `attest-image.yml`, pinned by full commit, which signs it
  keylessly and attests its SBOM and provenance, as mcl-echo's does. Every
  action is pinned by commit. Only `main` publishes `:latest` and only a `v*`
  tag a version; any other ref is refused.
- Built in `macula-ci-otp-rocksdb` and run on `macula-pq-runtime-rocksdb`
  (Debian trixie), pinned by their dated tag and digest (`20260928-1642`);
  rocksdb links the system librocksdb (`-DWITH_SYSTEM_ROCKSDB=ON`) instead of
  compiling its bundled copy. It used to build and run on alpine.
- The image carries its own `org.opencontainers.image.revision` (build-push
  passes the commit). Without it, it inherited its base image's label, which
  named a macula-ci-images commit.
- The boot claim carries `MCL_SERVICE_NAME=mcl-rag` and the deploying host's
  `MCL_BOX`, so the realm's Providers desk shows the service and box.
- Every app lists only the dependencies its own modules call or implement,
  held by a test that reads the compiled beams (`mcl_rag_app_deps_tests`).
  `embed_corpus`, `refresh_corpus` and `serve_retrieval` no longer list
  `reckon_db` and `reckon_evoq` (the service has no event store), `rag` no
  longer lists `barrel_docdb` (barrel brings it) and `mcl_rag` no longer lists
  `barrel` (rag brings it). This removes redundant declarations only: mcl_om
  0.33 itself lists `reckon_db`, `evoq` and `reckon_evoq`, so they still start,
  idle, until mcl_om drops them (mcl-om#10: a service that wants a store lists
  it itself). `evoq` is listed by the three apps whose commands use it.

### Fixed

- barrel_docdb's system database lives on the data volume. Its `data_dir`
  default is `data/barrel_docdb` relative to the working directory, inside
  the container.
- The ports are the registered ones (macula-fleet `PORTS.md`): health 8450,
  the loopback HTTP API 8451. The image had said 8470, which is mcl-sentinel's,
  and under host networking a collision is a silent bind failure.
- The corpus-sync NIF is built in the image, against the image's own
  libraries. The port had committed a workstation build, which would never
  have loaded in the image. A root-anchored `.gitignore` rule had let it
  through.
- The health check's start period (900 s) outlasts the store open, which
  rebuilds the vector index and takes minutes.

