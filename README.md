# mcl-rag

**The mesh shared memory: retrieval over a realm-bound corpus, and the deposits agents remember into it**

## What it does

It holds the mesh's shared memory: documents from a set of git repos plus the
knowledge agents deposit, chunked and embedded (384 dims,
`intfloat/multilingual-e5-small`, vectors from `mcl-embedder` over the mesh),
and answers retrieval over it. It also serves as one shard of the org's
federated retrieval (`macula_rag`, procedure `mcl-rag/rag.query_shard_v1`).

The data is one barrel database, `rag_chunks`, under `MCL_DATA_DIR`, next to the
corpus checkouts. `deploy/corpus-repos.json` lists the repos. The node keeps
them fast-forwarded (vendored libgit2, HTTPS only) and re-embeds whatever
changes. The ids in that file are the watermark namespace, so renaming one
re-embeds that repo from scratch.

## The procedures

Seventeen, each served as `mcl-rag/<name>` (version 1) under the org
`mcl-rag`. The realm has to grant this node a provider authorization for each
one (D25). Until it does, nothing is advertised and `/health` names the
missing grants.

| Open to any caller the station admits | Operator-only |
|---|---|
| `answer_query`, `rerank_results`, `search_chunks_semantic`, `get_chunk_by_id`, `list_chunks_by_source`, `get_source_by_id`, `list_sources_page`, `get_document_verbatim`, `add_knowledge` | `prune_chunks`, `retire_document`, `ingest_document`, `upload_knowledge`, `embed_document`, `classify_topics`, `schedule_reembed`, `detect_corpus_change` |

**Operators** are the node ids in `MCL_RAG_OPERATORS`. The check reads the
caller as macula verified it on the wire, never a field the caller wrote. An
operator-only procedure refuses everyone else with `not_an_operator`. An empty
list means nobody, which is a valid setting. Anyone running
`macula-cli upload_knowledge` has to be listed.

Known callers: `macula-mcp` (`mesh_recall`, `mesh_remember`), `macula-cli` and
`macula-lazymesh`.

## Health

`/health` on `MCL_HEALTH_PORT` returns `ok` once the store is open and the org
can reach this shard. Opening the store rebuilds the vector index, which takes
over three minutes on the production corpus (longer on a Celeron). While it
runs, `/health` reports `degraded, store_opening` and every call is refused with
`{error, store_opening}`. That is by design. The image's health check has a
900 s start period to cover the open.

## Running it

    rebar3 compile
    rebar3 eunit
    rebar3 ct                              # starts the real application, per suite
    rebar3 dialyzer
    rebar3 lint

    scripts/health.sh                      # against a running node

Building the image needs a Rust toolchain. macula ships a QUIC NIF, and this
service has its own corpus-sync NIF (`native/mcl_rag_corpus_sync_nif`). The
alpine build compiles both from source, because a binary built elsewhere links
a different libc. Locally, `scripts/build-corpus-sync-nif.sh` builds the
corpus-sync NIF into `priv/lib/`, which is gitignored.

    podman build -t mcl-rag -f Containerfile .

## Configuration

| Variable | Default | Meaning |
|----------|---------|---------|
| `MCL_REALM` | required | 64-hex realm tag, the `sha256` of the realm's name. No default: a service that guesses its realm announces itself where nobody can attribute it. |
| `MCL_REALM_KEY` | required | The realm's public signing key, hex encoded: the **trust anchor**, not an identifier. Every org-namespaced advertisement is verified against it, so without it nothing resolves, the boot claim never reaches the realm, and the service stays green while unreachable. Public material, not a secret. |
| `MACULA_STATION_SEEDS` | required | Station hosts to dial, `host[:port]`, comma-separated. No default: naming a realm costs nothing, dialling a production station from every dev clone does. |
| `MACULA_STATION_NODE_IDS` | required | The matching 64-hex station node ids, comma-separated, index-paired with the seeds. The 11.x dial is pinned (D5): mcl_om refuses to boot a pool with an unpinned seed. |
| `MCL_REALM_NAME` | required | The realm's name. Its `sha256` must be `MCL_REALM`, or joining the federation is refused and `/health` reports down. |
| `MCL_RAG_OPERATORS` | empty | Node ids (64 hex, comma-separated) allowed to call the operator-only procedures. Empty means nobody. |
| `MCL_RAG_TOPIC_API_KEY` | empty | Groq key for topic classification. It is a secret: supply it from the host, never commit it. |
| `MCL_RAG_TOPIC_FALLBACK_API_KEY` | empty | DeepSeek key, used when Groq fails. |
| `MCL_DATA_DIR` | `/var/lib/mcl-rag` | The store and the corpus checkouts. Mount it on a persistent volume (compose names it `mcl-rag-data`). |
| `MCL_RAG_HTTP_PORT` | `8470` | The local HTTP API. |
| `MCL_RAG_HTTP_IP` | `127.0.0.1` | Keep it on loopback: the API has writes and no authentication. |
| `MCL_HEALTH_PORT` | `8450` | Health endpoint. Host networking makes a collision a silent bind failure, so check the host before changing.  |
| `MCL_NODE_NAME` | `mcl_rag` | Erlang node name. |
| `MCL_NODE_HOST` | `127.0.0.1` | Erlang node host. |
| `MCL_COOKIE` | `mcl_rag` | Erlang cookie. |

`deploy/docker-compose.yml` runs it, and carries what the service knows about
itself. If you deploy through something else, let that carry **placement**: which
host, which station, which realm, which secret store. Keeping the two apart is
what stops a config table in a README and the real environment drifting.

## Deployment

CI builds on every push to `main` and on `v*` tags, and pushes
`ghcr.io/macula-services/mcl-rag:latest` plus the semver tag. Fleet boxes run
an image pinned in `macula-fleet`, never `:latest`, so a merge is not a deploy.
To roll back, revert the pin.

Three things CI cannot do for you:

1. The registry package may be created **private**, and the pull then fails on
   the host with a bare `unauthorized` that names nothing. Check it after the
   first build. On ghcr the `org.opencontainers.image.source` label in the
   Containerfile is what links the package to the repository.
2. The host needs `MCL_REALM`, `MCL_REALM_NAME`, `MCL_REALM_KEY` and the
   pinned station pair supplied from somewhere they are not committed, and
   the topic keys from its secrets.
3. The data volume is the memory. Recreating the container keeps it, but
   removing `mcl-rag-data` wipes it, and the node then re-embeds the whole
   corpus.

## The service contract

Six callbacks in `mcl_rag_service`, all required, all resolved **by name** by
`mcl_om` at startup on a live node. The `-behaviour(mcl_om_service)`
attribute turns a missing one into a compile error rather than an `undef` where
nobody is watching, and the eunit suite guards the attribute itself.

## Licence

Apache-2.0.
