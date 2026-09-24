# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

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
  default is `/tmp/barrel_data`, inside the container.
- The ports are the registered ones (macula-fleet `PORTS.md`): health 8450,
  the loopback HTTP API 8451. The image had said 8470, which is mcl-sentinel's,
  and under host networking a collision is a silent bind failure.
- The corpus-sync NIF is built in the image, against the image's own
  libraries. The port had committed a workstation build, which would never
  have loaded in the image. A root-anchored `.gitignore` rule had let it
  through.
- The health check's start period (900 s) outlasts the store open, which
  rebuilds the vector index and takes minutes.
