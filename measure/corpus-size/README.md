# What a corpus checkout costs, and what `depth` and `paths` save

This exists so the bounds mcl-rag#5 added are picked from numbers, not guesses.

Measured 2026-10-10 on msi00, against the live corpus volume
(`mcl-rag-data-v2`, the 2026-10-10 state) and fresh depth-bounded clones of the
same branches, with the OS `git` (a measuring tool here, never a runtime
dependency: the service uses the vendored-libgit2 NIF). `measure.sh` is the
exact set of commands; sizes are `du -sm` disk usage.

## Where the 15 GB is

| repo | total | `.git` | worktree | ingestible markdown |
|---|---:|---:|---:|---:|
| kicad | 5688M | 4383M | 1305M | 0.9M (129 files) |
| rt-thread | 2336M | 1012M | 1324M | 5.8M (939) |
| zephyr | 1514M | 1006M | 508M | 0.09M (17) |
| esp-idf | 917M | 589M | 328M | 4.4M (1016) |
| erlang-otp | 889M | 649M | 240M | 8.4M (401) |
| freertos | 556M | 144M | 412M | 0.3M (115) |
| sdrangel | 536M | 263M | 273M | 1.4M (186) |
| circuitpython | 340M | 256M | 84M | 0.2M (68) |
| micropython | 131M | 81M | 50M | 0.3M (140) |
| librepcb | 93M | 66M | 27M | 0.1M (33) |

The other 41 of the 51 entries bring the corpus to 15G; these ten are where it
goes. Two readings:

- **The `.git` is most of a big code checkout** (66-77% of kicad/zephyr/otp).
  It holds the head's blobs too, so it does not shrink by itself.
- **What the ingest reads is a rounding error next to the tree** (kicad: 129
  markdown files, 0.9 MB, inside 5.7 GB). The download and the disk are spent
  on everything the walker never looks at.

## What `depth` does (fresh clones, same branches)

| clone | total | `.git` | clone time |
|---|---:|---:|---:|
| zephyr depth 1 | 650M | 142M | 52s |
| zephyr depth 50 | 650M | 142M | 44s |
| zephyr depth 500 | 651M | 143M | 33s |
| zephyr full (the live checkout) | 1514M | 1006M | - |
| kicad depth 1 | 1587M | 288M | 31s |
| kicad depth 50 | 1587M | 288M | 35s |
| kicad depth 500 | 1623M | 324M | 59s |
| kicad full (the live checkout) | 5688M | 4383M | - |

- **Depth is the win**: depth 1 cuts the `.git` by 86% (zephyr) and 93%
  (kicad). The rest of the history is where the gigabytes were.
- **Deeper buys almost nothing**: 500 commits over 1 costs +1M (zephyr) and
  +36M (kicad); text diffs compress, and the head tree is present at any depth.
- **Depth does not touch the worktree**: the head's tree is materialised fully
  (kicad depth 1 is still 1.3G on disk).
- A shallow checkout stays shallow; the service never deepens one, and nothing
  in it reads history (it syncs heads and reads the worktree), so a small
  depth costs it nothing.

## What `paths` does

`paths` bounds what is materialised and walked. It cannot bound the download:
libgit2 has no partial clone, so the fetch still brings the branch's objects.
For these repos that still leaves the worktree (and the walk) as the thing
`paths` fixes, and what the ingest reads is the small markdown subset above.

## What the numbers picked

- `depth` stays opt-in per entry; for these repos 1 is where the win is and
  deeper buys ~nothing.
- `paths` stays opt-in; it is worth setting for source repos whose ingestible
  markdown is a tiny slice (kicad, zephyr, esp-idf, otp), and pointless for
  all-markdown repos (the corpus repos themselves).
- Neither ships as a default value in `deploy/corpus-repos.json`: a list that
  carries bounds is its own reviewed change, per deployment.

## Limits

- Sizes are the 2026-10-10 tips of the branches the corpus follows, not the
  exact ingested objects (same heads; a handful of files may have moved since
  the corpus was fetched).
- Clone times are one run each on msi00's link; treat them as scale, not
  benchmarks.
