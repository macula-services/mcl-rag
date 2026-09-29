# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **On mcl_om 0.33.1, macula 13.0.1 and macula_rag 0.2** (evoq `~> 1.26.1`).
  The floors are mcl_om 0.33's own, and macula_rag 0.2 is its release on
  macula 13 (0.1 pinned macula 12). The info test checks both floors to the
  patch release.
- **The service requires the mesh** (`{mesh, required}`): a boot missing
  `MCL_REALM`, `MCL_REALM_KEY`, `MACULA_STATION_SEEDS` or
  `MACULA_STATION_NODE_IDS` stops and names each one.
- **Models on the node's own ollama, no key** (Raf, 2026-09-29). Embeddings
  come from ollama on loopback (`embed_provider ollama`), model
  `macula/multilingual-e5-small:f16`, built on msi00 from intfloat's own
  weights, 384 dimensions as before. The topic classifier asks the same
  ollama's OpenAI-compatible endpoint, `qwen2.5:7b-instruct-q4_K_M`. The Groq
  primary, the DeepSeek fallback and both API keys are removed from the code
  and the config: `rag_topic_classifier` has one backend, sends no
  credentials, and returns a failure as it is.
- **The image is signed.** build-push hands the pushed digest to
  macula-ci-images' `attest-image.yml`, pinned by full commit, which signs it
  keylessly and attests its SBOM and provenance. Every action is pinned by
  commit. Only `main` publishes `:latest` and only a `v*` tag a version; any
  other ref is refused.
- The rocksdb image pair is pinned by its dated tag and digest
  (`20260928-1642`); builder and runtime are one publication and CI builds in
  the same builder.
- `deploy/docker-compose.yml` runs the image by digest
  (`MCL_RAG_IMAGE_DIGEST`); no `:latest`, no watchtower, no key variables.

### Added

- The C4 model (context, containers, components) in `architecture/`, with its
  diagrams in `assets/`.
- `measure/e5_prefixes/`: a pre-registered measurement of whether e5's
  `query: ` / `passage: ` prefixes help retrieval on the msi00 model (corpus,
  queries, k and rule fixed before any result).

- **mcl_om `~> 0.28` with macula `~> 12.2`, together.** Under macula 12.2 an
  mcl_om older than 0.28 lets a failed publish announcement kill the
  publishing process. The service answers `mcl-rag/info` with no code of its
  own (which also makes it count as online on the realm's Providers desk), and
  `mcl_rag_info_tests` round-trips it through macula's codec and fails unless
  it reports mcl_om 0.28 with macula 12.2.
- The image carries its own `org.opencontainers.image.revision` (build-push
  passes the commit). Without it, it inherited its base image's label, which
  named a macula-ci-images commit.

### Added

- The port of `hecate-rag` onto `mcl_om` and macula 12: the same barrel store
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
- `deploy/docker-compose.yml` carries the whole run contract: the realm name,
  the operators, the topic keys, a named data volume and the corpus list.
  An eunit suite holds the Containerfile, compose and the templated configs to
  each other.

### Changed

- On `mcl_om` 0.27, which no longer brings `barrel_docdb`. This service
  declares it itself, and rocksdb links the system librocksdb
  (`-DWITH_SYSTEM_ROCKSDB=ON`) instead of compiling its bundled copy. It builds
  in `macula-ci-otp-rocksdb` and runs on `macula-pq-runtime-rocksdb` (Debian
  trixie), both pinned by digest. It used to build and run on alpine.
- The boot claim carries `MCL_SERVICE_NAME=mcl-rag` and the deploying host's
  `MCL_BOX`, so the realm's Providers desk shows the service and box.

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
