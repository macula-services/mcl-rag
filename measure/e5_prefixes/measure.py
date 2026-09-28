#!/usr/bin/env python3
"""Recall@5 and MRR@10 of the embedding model with and without e5's
"query: " / "passage: " prefixes, on the fixed corpus and queries beside this
file (see PREREGISTRATION.md). Standard library only; embeds through ollama's
/api/embed at --url, as mcl-rag does.

    measure.py --model macula/multilingual-e5-small:f16 [--url http://127.0.0.1:11434]
"""
import argparse, json, math, os, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
K, MRR_AT = 5, 10

def embed(url, model, texts):
    req = urllib.request.Request(url + "/api/embed", data=json.dumps({"model": model, "input": texts}).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=600) as r:
        return json.load(r)["embeddings"]

def cos(a, b):
    return sum(x * y for x, y in zip(a, b)) / (math.sqrt(sum(x * x for x in a)) * math.sqrt(sum(y * y for y in b)))

def run(url, model, corpus, queries, prefixed):
    p = [("passage: " if prefixed else "") + d["text"] for d in corpus]
    q = [("query: " if prefixed else "") + x["text"] for x in queries]
    pv, qv = embed(url, model, p), embed(url, model, q)
    dims = {len(v) for v in pv + qv}
    hits, rr, ranks = 0, 0.0, {}
    for x, v in zip(queries, qv):
        order = sorted(range(len(corpus)), key=lambda i: -cos(v, pv[i]))
        rank = [corpus[i]["id"] for i in order].index(x["relevant"]) + 1
        ranks[x["id"]] = rank
        hits += rank <= K
        rr += 1.0 / rank if rank <= MRR_AT else 0.0
    return {"prefixed": prefixed, "dims": sorted(dims), "recall_at_5": hits / len(queries),
            "mrr_at_10": round(rr / len(queries), 4), "ranks": ranks}

def main():
    a = argparse.ArgumentParser()
    a.add_argument("--model", required=True)
    a.add_argument("--url", default="http://127.0.0.1:11434")
    o = a.parse_args()
    corpus = json.load(open(os.path.join(HERE, "corpus.json")))
    queries = json.load(open(os.path.join(HERE, "queries.json")))
    out = {"model": o.model, "k": K, "passages": len(corpus), "queries": len(queries),
           "raw": run(o.url, o.model, corpus, queries, False),
           "prefixed": run(o.url, o.model, corpus, queries, True)}
    print(json.dumps(out, indent=1))

if __name__ == "__main__":
    main()
