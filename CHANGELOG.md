# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

