# mcl-rag

**The mesh shared memory: retrieval over a realm-bound corpus, and the deposits agents remember into it**

Architecture: the C4 model (context, containers, components) is in [architecture/README.md](architecture/README.md).

## What it does

It holds the mesh's shared memory: documents from a set of git repos plus the
knowledge agents deposit, chunked and embedded (384 dims,
`intfloat/multilingual-e5-small`, from the node's own ollama on loopback, where
it is named `macula/multilingual-e5-small:f16`; stored text is embedded with
e5's `passage: ` prefix and queries with `query: `, see
[`measure/e5_prefixes`](measure/e5_prefixes/PREREGISTRATION.md)),
and answers retrieval over it. It also serves as one shard of the org's
federated retrieval (`macula_rag`, procedure `mcl-rag/rag.query_shard_v1`).

The data is one barrel database, `rag_chunks`, under `MCL_DATA_DIR`, next to the
corpus checkouts. `deploy/corpus-repos.json` lists the repos, each pinned to a
reviewed `commit` on its `branch`. The node fetches the branch and checks out
exactly that commit (vendored libgit2, HTTPS only), so a push to a corpus repo
changes nothing until the list moves its pin; it re-embeds whatever changes. The ids in that file are the watermark namespace, so renaming one
re-embeds that repo from scratch.
To serve your own corpus, see [Run your own corpus](docs/RUN_YOUR_OWN_CORPUS.md).

## The procedures

Eighteen, each served as `mcl-rag/<name>` (version 1) under the org
`mcl-rag`. The realm has to grant this node a provider authorization for each
one (D25). Until it does, nothing is advertised and `/health` names the
missing grants.

| Open to any caller the station admits | Operator-only |
|---|---|
| `describe_corpus`, `answer_query`, `rerank_results`, `search_chunks_semantic`, `get_chunk_by_id`, `list_chunks_by_source`, `get_source_by_id`, `list_sources_page`, `get_document_verbatim`, `add_knowledge` | `prune_chunks`, `retire_document`, `ingest_document`, `upload_knowledge`, `embed_document`, `classify_topics`, `schedule_reembed`, `detect_corpus_change` |

**Operators** are the node ids in `MCL_RAG_OPERATORS`. The check reads the
caller as macula verified it on the wire, never a field the caller wrote. An
operator-only procedure refuses everyone else with `not_an_operator`. An empty
list means nobody, which is a valid setting. Anyone running
`macula-cli upload_knowledge` has to be listed.

Known callers: `macula-mcp` (`mesh_recall`, `mesh_remember`), `macula-cli` and
`macula-lazymesh`.

## Provenance and corpus identity

mcl-rag is the reference implementation of the RAG service contract
(macula-architecture `plans/DESIGN_RAG_SERVICE_CONTRACT.md`).

- **Every hit says where it came from.** A search hit, a chunk fetched by id,
  a source row, a verbatim document and a federated hit all carry
  `provenance`: `kind` (`corpus` or `deposit`), `path`, `content_sha256` (the
  sha256 of the stored text), plus `repo_id` and `commit` for corpus content,
  the lines for a chunk, and `deposited_by` for a deposit whose depositor is
  known. `commit` is the pin the content was ingested at. A file unchanged
  across a pin move keeps it, since its bytes are the same at the new pin.
- **Every answer names its corpus.** `answer_query` replies
  `{corpus_hash, hits}`. `describe_corpus` returns `corpus_hash`, `model`,
  `dim` and `repos` (id, url, branch, commit). `corpus_hash` is the lowercase
  hex sha256 of the RFC 8785 canonical JSON of
  `{"dim", "model", "repos": [{"branch", "commit", "id", "url"}]}`, repos in
  list order, so a caller can recompute it. With no corpus list, the corpus
  is empty and still named; a list that is refused makes both calls refuse.
- **The operator signs its corpus.** With an identity key, `describe_corpus`
  also returns `signature`, a macula signed object (CBOR bytes, carrying its
  key) over `{corpus_hash}` under the label `macula-rag corpus v1`, and
  `signed_by`, the hex node id of that key, a display label only. Without an
  identity key the corpus is unsigned and neither field is present.

  The signature is static, so any provider can copy another's. A caller treats
  a corpus as signed by node P only when all of these hold:
  1. it called P itself: `macula:call/6` with `#{provider => P}`, P taken from
     `macula:providers/3`. A `macula:call/5` caller does not know who
     answered, so it treats the corpus as **unsigned**;
  2. `macula_signed_object:verify/3` accepts the object under the label and
     the caller's profile;
  3. the node id derived from the `key` that `verify/3` returns
     (`macula_node_keys:node_id(Key, Profile)`) is P. `signed_by` is never
     evidence;
  4. the signed `corpus_hash` equals the one the caller **recomputed** from
     the described `model`, `dim` and `repos`, and the one on its
     `answer_query` replies from P.

  The signature says P vouched for that corpus; it does not say when.

## Health

`/health` on `MCL_HEALTH_PORT` returns `ok` once the store is open and the org
can reach this shard. Opening the store rebuilds the vector index, which takes
over three minutes on the full corpus (longer on a Celeron). While it
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

The build and CI run in `ghcr.io/macula-io/macula-ci-otp-rocksdb`, and the
image runs on `ghcr.io/macula-io/macula-pq-runtime-rocksdb`, both pinned by
digest. rocksdb links the system librocksdb 11.1.2 those images carry (the
override in `rebar.config`), so building outside them stops at "Could not find
RocksDB" unless your machine has that library. This service's own corpus-sync
NIF (`native/mcl_rag_corpus_sync_nif`, Rust) is built inside the image, never
copied in; locally, `scripts/build-corpus-sync-nif.sh` builds it into
`priv/lib/`, which is gitignored.

    podman build -t mcl-rag -f Containerfile .

## Configuration

| Variable | Default | Meaning |
|----------|---------|---------|
| `MCL_REALM` | required | 64-hex realm tag, the `sha256` of the realm's name. No default: a service that guesses its realm announces itself where nobody can attribute it. |
| `MCL_REALM_KEY` | required | The realm's public signing key, hex encoded: the **trust anchor**, not an identifier. Every org-namespaced advertisement is verified against it, so without it nothing resolves, the boot claim never reaches the realm, and the service stays green while unreachable. Public material, not a secret. |
| `MACULA_STATION_SEEDS` | required | Station hosts to dial, `host[:port]`, comma-separated. No default: naming a realm costs nothing, dialling a fleet station from every dev clone does. |
| `MACULA_STATION_NODE_IDS` | required | The matching 64-hex station node ids, comma-separated, index-paired with the seeds. The 11.x dial is pinned (D5): mcl_om refuses to boot a pool with an unpinned seed. |
| `MCL_REALM_NAME` | required | The realm's name. Its `sha256` must be `MCL_REALM`, or joining the federation is refused and `/health` reports down. |
| `MCL_RAG_OPERATORS` | empty | Node ids (64 hex, comma-separated) allowed to call the operator-only procedures. Empty means nobody. |
| `MCL_RAG_CORPUS_REPOS` | `/etc/mcl-rag/corpus-repos.json` | The corpus list: every repo pinned to a reviewed commit, in the shape [`schema/corpus-repos.schema.json`](schema/corpus-repos.schema.json) publishes. A list that breaks it is refused whole, naming the entry. See [Run your own corpus](docs/RUN_YOUR_OWN_CORPUS.md). |
| `MCL_DATA_DIR` | `/var/lib/mcl-rag` | The store and the corpus checkouts. Mount it on a persistent volume (compose names it `mcl-rag-data`). |
| `MCL_RAG_IMAGE_DIGEST` | required by the compose file | `sha256:<digest>` of the released image to run: the compose file runs the image by digest, never by tag. |
| `MCL_RAG_HTTP_PORT` | `8451` | The local HTTP API. Registered in macula-fleet `PORTS.md`, like the health port. |
| `MCL_RAG_HTTP_IP` | `127.0.0.1` | Keep it on loopback: the API has writes and no authentication. |
| `MCL_SERVICE_NAME` | `mcl-rag` | Label on the boot claim the realm's operator sees on the Providers desk. |
| `MCL_BOX` | from the host | Label naming the box, also on the boot claim. Set it where you deploy. |
| `MCL_HEALTH_PORT` | `8450` | Health endpoint. Host networking makes a collision a silent bind failure, so check the host before changing.  |
| `MCL_NODE_NAME` | `mcl_rag` | Erlang node name. |
| `MCL_NODE_HOST` | `127.0.0.1` | Erlang node host. |
| `MCL_COOKIE` | `mcl_rag` | Erlang cookie. |

`deploy/docker-compose.yml` runs it, and carries what the service knows about
itself. If you deploy through something else, let that carry **placement**: which
host, which station, which realm, which secret store. Keeping the two apart is
what stops a config table in a README and the real environment drifting.

## Deployment

A `v*` tag publishes `ghcr.io/macula-services/mcl-rag:<version>` and nothing
else, and the attest job signs that digest keylessly with its SBOM and
provenance (macula-ci-images' `attest-image.yml`, pinned by commit); a box that
enforces signatures refuses any other. A push to `main` publishes `:latest`, the
tip of main to try; nothing on the fleet follows it. Fleet boxes run an image
pinned by digest in `macula-fleet`, so a merge is not a deploy. To roll back,
revert the pin.

Three things CI cannot do for you:

1. The registry package may be created **private**, and the pull then fails on
   the host with a bare `unauthorized` that names nothing. Check it after the
   first build. On ghcr the `org.opencontainers.image.source` label in the
   Containerfile is what links the package to the repository.
2. The host needs `MCL_REALM`, `MCL_REALM_NAME`, `MCL_REALM_KEY`, the pinned
   station pair and `MCL_RAG_IMAGE_DIGEST` supplied from its deploy config,
   and its own ollama on `127.0.0.1:11434` holding the embedding model
   (`macula/multilingual-e5-small:f16`) and the classifier's
   (`qwen2.5:7b-instruct-q4_K_M`). No API key: both models are local.
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
