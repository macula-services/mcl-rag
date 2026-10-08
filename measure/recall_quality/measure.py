#!/usr/bin/env python3
"""Recall quality on a live mcl-rag: for each fixed query beside this file, the
top hits of /api/rag/chunks/search and three counts over them (#26, #25):

  boilerplate  a hit that is a licence or copyright block, a .github template,
               or a file such as LICENSE, NOTICE or COPYING
  duplicate    a hit whose content_sha256 an earlier hit already had
  stale        a corpus hit whose commit is not the one describe_corpus names
               for its repo (only with --corpus, a describe_corpus result)

A regression check: after #24-#26 all three are 0 on every query. Standard
library only.

    measure.py --url http://127.0.0.1:8451 [--top-k 5] [--corpus describe.json] [--json]
"""
import argparse, json, os, re, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))

BOILERPLATE_PATH = re.compile(r"(^|/)(LICEN[CS]E|COPYING|NOTICE)([._-][^/]*)?$|(^|/)\.github/", re.I)
BOILERPLATE_TEXT = re.compile(
    r"%CopyrightBegin%|Licensed under the Apache License|SPDX-License-Identifier|"
    r"Permission is hereby granted, free of charge|GNU (Lesser |Affero )?General Public License|"
    r"THE SOFTWARE IS PROVIDED \"AS IS\"", re.I)


def search(url, text, top_k):
    body = json.dumps({"query_text": text, "top_k": top_k}).encode()
    req = urllib.request.Request(url + "/api/rag/chunks/search", data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)["items"]


def served_commits(path):
    with open(path) as f:
        described = json.load(f)
    described = described.get("result", described)
    return {r["id"]: r["commit"] for r in described.get("repos", [])}


def judged(hit, seen, served):
    prov = hit.get("provenance") or {}
    path = prov.get("path") or hit.get("source_path") or ""
    sha = prov.get("content_sha256")
    flags = []
    if BOILERPLATE_PATH.search(path) or BOILERPLATE_TEXT.search(hit.get("content") or ""):
        flags.append("boilerplate")
    if sha and sha in seen:
        flags.append("duplicate")
    if served is not None and prov.get("kind") == "corpus" and served.get(prov.get("repo_id")) != prov.get("commit"):
        flags.append("stale")
    seen.add(sha)
    return {"path": path, "score": round(hit.get("score", 0.0), 4), "commit": (prov.get("commit") or "")[:7],
            "flags": flags}


def main():
    a = argparse.ArgumentParser()
    a.add_argument("--url", required=True)
    a.add_argument("--top-k", type=int, default=5)
    a.add_argument("--corpus", help="a describe_corpus result (JSON), to count stale hits")
    a.add_argument("--json", action="store_true")
    args = a.parse_args()
    served = served_commits(args.corpus) if args.corpus else None
    with open(os.path.join(HERE, "queries.json")) as f:
        queries = json.load(f)
    report, totals = [], {"boilerplate": 0, "duplicate": 0, "stale": 0}
    for q in queries:
        seen = set()
        hits = [judged(h, seen, served) for h in search(args.url, q["text"], args.top_k)]
        for h in hits:
            for flag in h["flags"]:
                totals[flag] += 1
        report.append({"id": q["id"], "text": q["text"], "hits": hits})
    if args.json:
        print(json.dumps({"top_k": args.top_k, "totals": totals, "queries": report}, indent=1))
        return
    for q in report:
        print(f"{q['id']} {q['text']}")
        for h in q["hits"]:
            print(f"   {h['score']:.4f} {h['commit']:7} {','.join(h['flags']) or '-':20} {h['path']}")
    print("totals:", json.dumps(totals))


if __name__ == "__main__":
    main()
