# Run your own corpus

This exists so you can serve a corpus of your own on the mesh, from your own box, answering the
same calls mcl-rag answers, with nobody to ask.

mcl-rag is the reference implementation of the RAG service contract
(macula-architecture `plans/DESIGN_RAG_SERVICE_CONTRACT.md`). There is no central registry:
callers find you through your realm and decide for themselves whether to trust your corpus.

## 1. Write the list

A corpus list names git repos, each pinned to one reviewed commit on its branch:

```json
{"repos": [
  {"id": "handbook", "url": "https://github.com/example-org/handbook.git",
   "branch": "main", "commit": "0123456789abcdef0123456789abcdef01234567"},
  {"id": "runbooks", "url": "/srv/mirrors/runbooks.git",
   "branch": "main", "commit": "89abcdef0123456789abcdef0123456789abcdef"}
]}
```

The rules are published as [`schema/corpus-repos.schema.json`](../schema/corpus-repos.schema.json),
and the service refuses a list that breaks them, naming the entry:

| Field | Rule | Refusal |
|---|---|---|
| `id` | lowercase letters, digits and dashes, unique in the list. It names the checkout directory and the ingest namespace (`<id>/<path>`), so renaming one re-ingests that repo | `malformed_id`, `duplicate_id` |
| `url` | `https://`, or an absolute path to a git repo on your own box (a local mirror). No credentials are ever used | `unsupported_url` |
| `branch` | non-empty; it must contain `commit` | `missing_branch`, then `commit_not_on_branch` at sync |
| `commit` | 40 lowercase hex | `unpinned_repo`, `malformed_commit` |
| anything else | not allowed | `unknown_key` |

Validate the list before you ship it with any JSON Schema 2020-12 validator, for example
`check-jsonschema --schemafile schema/corpus-repos.schema.json corpus-repos.json`.

## 2. Pin the commits

Take each branch head and review it before you pin it:

```bash
git ls-remote https://github.com/example-org/handbook.git refs/heads/main
```

The service checks out exactly the listed commit and never follows the branch. A push to one of
your repos reaches answers only when you move its pin. Moving a pin is the review step.

## 3. Point the service at it

Set `MCL_RAG_CORPUS_REPOS` to the list's path inside the container, or mount the list at the
default, `/etc/mcl-rag/corpus-repos.json` (as `deploy/docker-compose.yml` does). The file is
re-read every sync tick (120 s), so a changed list takes effect without a restart.

Everything else is in the README's Configuration table: your realm (`MCL_REALM`,
`MCL_REALM_NAME`, `MCL_REALM_KEY`), stations to dial, and the data volume.

## 4. Get your grants

Your realm's operator grants your node a provider authorization for each procedure you serve.
Until then nothing is advertised, and `/health` names the missing grants.

## 5. Be found

Callers look up `answer_query` providers in the realms they trust (DHT
`procedure_advertisement` records) and choose among them. Whether a caller trusts your corpus is
up to the caller.
