# Run your own corpus

This exists so you can serve a corpus of your own on the mesh, from your own box, answering the
same calls mcl-rag answers, with nobody to ask.

mcl-rag is the reference implementation of the RAG service contract
(macula-architecture `plans/DESIGN_RAG_SERVICE_CONTRACT.md`). There is no central registry:
callers find you through your realm and decide for themselves whether to trust your corpus.

## 1. Write the list

A corpus list names git repos and the branch each one is followed on. Knowledge evolves, so
nothing is pinned: the service follows each branch head.

```json
{"repos": [
  {"id": "handbook", "url": "https://github.com/example-org/handbook.git", "branch": "main"},
  {"id": "runbooks", "url": "/srv/mirrors/runbooks.git", "branch": "main"}
]}
```

The rules are published as [`schema/corpus-repos.schema.json`](../schema/corpus-repos.schema.json),
and the service refuses a list that breaks them, naming the entry:

| Field | Rule | Refusal |
|---|---|---|
| `id` | lowercase letters, digits and dashes, unique in the list. It names the checkout directory and the ingest namespace (`<id>/<path>`), so renaming one re-ingests that repo | `malformed_id`, `duplicate_id` |
| `url` | `https://`, or an absolute path to a git repo on your own box (a local mirror). No credentials are ever used | `unsupported_url` |
| `branch` | non-empty; its head is what is served | `missing_branch` |
| anything else, `commit` included | not allowed | `unknown_key` |

Validate the list before you ship it with any JSON Schema 2020-12 validator, for example
`check-jsonschema --schemafile schema/corpus-repos.schema.json corpus-repos.json`.

## 2. What the service does with it

Every 2 hours the service fetches each branch and checks out its head. When a head has moved, it
re-ingests the files that changed, retires the files that are gone, and drops everything of a
repo that left the list. Each answer names the commit its text is present at, and
`describe_corpus` names the commit each repo is served at. A push to one of your repos reaches
answers on the next refresh.

## 3. Point the service at it

Set `MCL_RAG_CORPUS_REPOS` to the list's path inside the container, or mount the list at the
default, `/etc/mcl-rag/corpus-repos.json` (as `deploy/docker-compose.yml` does). The file is
re-read every refresh (2 h), so a changed list takes effect without a restart.

Everything else is in the README's Configuration table: your realm (`MCL_REALM`,
`MCL_REALM_NAME`, `MCL_REALM_KEY`), stations to dial, and the data volume.

## 4. Get your grants

Your realm's operator grants your node a provider authorization for each procedure you serve.
Until then nothing is advertised, and `/health` names the missing grants.

## 5. Be found

Callers look up `answer_query` providers in the realms they trust (DHT
`procedure_advertisement` records) and choose among them. Whether a caller trusts your corpus is
up to the caller.
