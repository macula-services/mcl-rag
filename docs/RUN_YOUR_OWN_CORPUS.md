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
| `depth` | optional; a positive integer; the repo's first clone fetches only that many commits (a shallow checkout). Absent or 0 fetches the full history. It applies at the first clone: a checkout that already exists full is not converted (delete it to pick this up), and a shallow one stays shallow, its later fetches bringing only new commits | `malformed_depth` |
| `paths` | optional; a non-empty list of file or directory prefixes, relative to the repo root (`docs`, `Documentation/guides`); only what is under one of them is materialised and ingested. Letters, digits and `. _ - /` beyond the first character, no `..` segment, no leading slash or dot | `malformed_paths`, `malformed_path` |
| anything else, `commit` included | not allowed | `unknown_key` |

Validate the list before you ship it with any JSON Schema 2020-12 validator, for example
`check-jsonschema --schemafile schema/corpus-repos.schema.json corpus-repos.json`.

## 2. What the service does with it

Every 2 hours the service fetches each branch and checks out its head. When a head has moved, it
re-ingests the files that changed, retires the files that are gone, and drops everything of a
repo that left the list. Each answer names the commit its text is present at, and
`describe_corpus` names the commit each repo is served at. A push to one of your repos reaches
answers on the next refresh.

Two optional keys keep a big code repo from costing what its whole history and tree would
(mcl-rag#5):

- `depth` bounds the first clone: a shallow checkout holds only the last commits, and for the
  corpora measured so far that is where almost all of the `.git` size goes (kicad dropped from
  4.3 GB of history to 288 MB at depth 1; zephyr from 1.0 GB to 142 MB). The refresh reads only
  the worktree at the head, so a small depth loses it nothing. It applies at the first clone
  only: a checkout that already exists full is not converted (delete it to pick this up), and
  it never deepens one again, so do not add `depth` expecting the history to come back later.
- `paths` bounds the working tree: only files under the listed prefixes are materialised and
  read. What such a repo actually ingests is often tiny next to its checkout (kicad: 0.9 MB of
  markdown in a 5.7 GB tree), so this is worth setting for source repos. A file outside the
  paths that an earlier full checkout left on disk is never touched, pruned or read.

Neither is a partial clone: the fetch still brings the branch's objects, so bound the download
with `depth`; `paths` shields the disk and the walk.

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
