# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

### Fixed

- The corpus-sync NIF is built in the image against musl. The port had
  committed a workstation build, which links glibc and would never have
  loaded on alpine. A root-anchored `.gitignore` rule had let it through.
- The health check's start period (900 s) outlasts the store open, which
  rebuilds the vector index and takes minutes.
