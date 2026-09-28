# Do e5's query/passage prefixes help mcl-rag's retrieval?

This exists so mcl-rag embeds text the way that retrieves best on the model it
runs (macula/multilingual-e5-small:f16, built on msi00 from intfloat's weights).

Fixed before any result was seen (this file, `corpus.json`, `queries.json` and
`measure.py` are committed before the run):

- **Corpus:** 35 passages, real Macula documentation (READMEs of mcl-mail,
  macula-rag, macula-ts, mcl-echo, macula-go), 250-900 characters each; badge
  and code-only paragraphs dropped.
- **Queries:** 20, paraphrased (not copied) from 20 of the passages, 15 English
  and 5 Dutch; each has exactly one relevant passage. The other 15 passages are
  distractors.
- **Model:** the one Terra declares for msi00, reached through ollama's
  `/api/embed` as mcl-rag's `barrel_embed_ollama` does. Cosine similarity.
- **Metrics:** recall@5 (primary), MRR@10 (secondary), per variant: raw text,
  and `passage: ` on passages with `query: ` on queries.
- **Decision rule:** intfloat documents the prefixes as how the model is meant
  to be used, so they are the default. mcl-rag adopts them (passage on
  add_knowledge/upload_knowledge, query on answer_query) UNLESS raw recall@5 is
  strictly higher; if recall@5 ties, MRR@10 decides the same way, and a tie on
  both keeps the prefixes.
- **What it cannot say:** 20 queries on 35 passages is one small set; a
  difference of one query is 0.05 recall. It decides this choice for this model,
  nothing broader.

Result: appended below after the run, with the model's manifest digest and the
exact command.
