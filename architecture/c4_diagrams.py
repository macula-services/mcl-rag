"""Generate mcl-rag's C4 diagrams: assets/c4-context.svg, assets/c4-containers.svg
and assets/c4-components.svg.

Run:  python3 architecture/c4_diagrams.py

The style block is the house one (mcl-fovea's): plain classes with literal
colours and a prefers-color-scheme: dark block, and no CSS custom properties,
because rsvg-convert renders those black. After a change, render each one
(rsvg-convert -w 1400 assets/c4-context.svg -o /tmp/c.png) and look at it;
keep architecture/README.md's tables in step.
"""
import os
from xml.sax.saxutils import escape

ASSETS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets")

SANS = '"Atkinson Hyperlegible", "Segoe UI", system-ui, -apple-system, Helvetica, Arial, sans-serif'
MONO = '"JetBrains Mono", ui-monospace, Menlo, Consolas, monospace'

STYLE = f"""<style>
.t-name {{ font-family: {SANS}; font-size: 15px; font-weight: 700; }}
.t-desc {{ font-family: {SANS}; font-size: 12.5px; }}
.t-rel {{ font-family: {SANS}; font-size: 11.5px; paint-order: stroke; stroke-width: 4px; stroke-linejoin: round; }}
.t-code {{ font-family: {MONO}; font-size: 13px; font-weight: 600; }}
.t-small {{ font-size: 12px; }}
.t-type {{ font-family: {MONO}; font-size: 11.5px; }}
.t-bound {{ font-family: {MONO}; font-size: 12px; font-weight: 600; }}
.edge {{ fill: none; stroke-width: 1.25; }}
.edge-later {{ fill: none; stroke-width: 1.25; stroke-dasharray: 5 4; }}
.bg {{ fill: #FFFFFF; }}
.b-sys {{ fill: #F5E9CC; stroke: #A56F0A; stroke-width: 2; }}
.b-ext {{ fill: #ECEFED; stroke: #8A9791; stroke-width: 1.25; }}
.b-per {{ fill: #E3EBF2; stroke: #3B5B7A; stroke-width: 1.25; }}
.b-cmp {{ fill: #FFFFFF; stroke: #8A9791; stroke-width: 1.25; }}
.b-later {{ fill: none; stroke: #8A9791; stroke-width: 1.25; stroke-dasharray: 5 4; }}
.bound {{ fill: none; stroke: #66736E; stroke-width: 1.25; stroke-dasharray: 7 5; }}
.bound-in {{ fill: none; stroke: #D9DFDC; stroke-width: 1.5; stroke-dasharray: 4 4; }}
.head {{ fill: #3B5B7A; }}
.t-name {{ fill: #16201D; }}
.t-code {{ fill: #16201D; }}
.t-type {{ fill: #66736E; }}
.t-desc {{ fill: #34413C; }}
.t-bound {{ fill: #66736E; }}
.t-rel {{ fill: #66736E; stroke: #FFFFFF; }}
.edge, .edge-later {{ stroke: #8A9791; }}
.arrowhead {{ fill: #8A9791; }}
@media (prefers-color-scheme: dark) {{
.bg {{ fill: #171F1C; }}
.b-sys {{ fill: #3A2E13; stroke: #E3AA3C; stroke-width: 2; }}
.b-ext {{ fill: #1C2421; stroke: #7D8B85; stroke-width: 1.25; }}
.b-per {{ fill: #1D2A36; stroke: #8EB4D8; stroke-width: 1.25; }}
.b-cmp {{ fill: #171F1C; stroke: #7D8B85; stroke-width: 1.25; }}
.b-later {{ fill: none; stroke: #7D8B85; stroke-width: 1.25; stroke-dasharray: 5 4; }}
.bound {{ fill: none; stroke: #93A09A; stroke-width: 1.25; stroke-dasharray: 7 5; }}
.bound-in {{ fill: none; stroke: #2A3431; stroke-width: 1.5; stroke-dasharray: 4 4; }}
.head {{ fill: #8EB4D8; }}
.t-name {{ fill: #E6ECE9; }}
.t-code {{ fill: #E6ECE9; }}
.t-type {{ fill: #93A09A; }}
.t-desc {{ fill: #C3CDC8; }}
.t-bound {{ fill: #93A09A; }}
.t-rel {{ fill: #93A09A; stroke: #171F1C; }}
.edge, .edge-later {{ stroke: #7D8B85; }}
.arrowhead {{ fill: #7D8B85; }}
}}
</style>"""

DEFS = ('<defs><marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" '
        'markerHeight="7" orient="auto-start-reverse"><path class="arrowhead" '
        'd="M0 0L10 5L0 10z"/></marker></defs>')


class Svg:
    def __init__(self, w, h, label):
        self.w, self.h, self.label = w, h, label
        self.parts = []

    def text(self, cls, x, y, s, anchor=None, rotate=None):
        a = f' text-anchor="{anchor}"' if anchor else ""
        r = f' transform="rotate({rotate} {x} {y})"' if rotate is not None else ""
        self.parts.append(f'<text class="{cls}" x="{x}" y="{y}"{a}{r}>{escape(s)}</text>')

    def rect(self, cls, x, y, w, h, rx=10):
        self.parts.append(f'<rect class="{cls}" x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}"/>')

    def element(self, cls, x, y, w, h, name, kind, desc, person=False):
        """A context or container element: name, [kind], description lines."""
        self.rect(cls, x, y, w, h)
        tx = x + 16
        if person:
            self.parts.append(f'<circle class="head" cx="{x + 26}" cy="{y + 24}" r="9"/>')
            tx = x + 44
        self.text("t-name", tx, y + 28, name)
        self.text("t-type", tx, y + 46, kind)
        for i, line in enumerate(desc):
            self.text("t-desc", x + 16, y + 70 + 16 * i, line)

    def component(self, cls, x, y, w, h, name, kind, desc, small=False):
        """A component: code name, [kind] right-aligned (or below when small)."""
        self.rect(cls, x, y, w, h, rx=8)
        self.text("t-code t-small" if small else "t-code", x + 14, y + 24, name)
        if small:
            self.text("t-type", x + 14, y + 42, kind)
            y0 = y + 62
        else:
            self.text("t-type", x + w - 12, y + 24, kind, anchor="end")
            y0 = y + 46
        for i, line in enumerate(desc):
            self.text("t-desc", x + 14, y0 + 16 * i, line)

    def row(self, cls, x, y, w, name, desc):
        """A one-line desk: name on the left, what it does on the right."""
        self.rect(cls, x, y, w, 34, rx=8)
        self.text("t-code t-small", x + 12, y + 22, name)
        self.text("t-desc", x + w - 12, y + 22, desc, anchor="end")

    def bound(self, cls, x, y, w, h, label):
        self.rect(cls, x, y, w, h, rx=12 if cls == "bound" else 10)
        self.text("t-bound", x + 16, y + 22, label)

    def edge(self, d, later=False):
        c = "edge-later" if later else "edge"
        self.parts.append(f'<path class="{c}" d="{d}" marker-end="url(#a)"/>')

    def write(self, name):
        head = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {self.w} {self.h}" role="img" '
                f'aria-label="{escape(self.label)}">',
                f"<title>{escape(self.label)}</title>", STYLE, DEFS,
                f'<rect class="bg" x="0" y="0" width="{self.w}" height="{self.h}"/>', ""]
        with open(os.path.join(ASSETS, name), "w") as f:
            f.write("\n".join(head + self.parts + ["</svg>", ""]))


# ---------------------------------------------------------------------------
# Level 1: system context
# ---------------------------------------------------------------------------
def context():
    s = Svg(1000, 660, "mcl-rag system context")

    # Edges first, so boxes and labels sit on top.
    s.edge("M135 130V200")                      # agent -> macula-mcp
    s.edge("M865 130V200")                      # operator -> macula-cli
    s.edge("M750 108H622V200")                  # operator -> local HTTP API
    s.edge("M250 262H370")                      # macula-mcp -> mcl-rag
    s.edge("M750 262H630")                      # macula-cli -> mcl-rag
    s.edge("M500 200V130")                      # mcl-rag -> corpus repos
    s.edge("M135 440V385H400V340")              # other shards -> mcl-rag
    s.edge("M440 340V440")                      # mcl-rag -> station
    s.edge("M580 340V440")                      # mcl-rag -> realm
    s.edge("M630 315H745V495H760")              # mcl-rag -> ollama

    s.element("b-per", 20, 30, 230, 100, "Agent", "[Person or AI agent]",
              ["Recalls and deposits shared", "memory through MCP tools"], person=True)
    s.element("b-ext", 390, 30, 220, 100, "Corpus repos", "[External: GitHub]",
              ["51 public repos listed in", "deploy/corpus-repos.json"])
    s.element("b-per", 750, 30, 230, 100, "Operator", "[Person]",
              ["Listed in MCL_RAG_OPERATORS;", "may rewrite or delete the store"],
              person=True)

    s.element("b-ext", 20, 200, 230, 130, "macula-mcp", "[External: MCP server]",
              ["Outside the fleet. mesh_recall,", "mesh_remember,",
               "mesh_remember_directory"])
    s.element("b-sys", 370, 200, 260, 140, "mcl-rag", "[Software system, mcl-om service]",
              ["The mesh's shared memory:", "chunks, embeds and retrieves",
               "over a realm-bound corpus;", "one shard of the org's retrieval"])
    s.element("b-ext", 750, 200, 230, 130, "macula-cli, lazymesh", "[External: mesh clients]",
              ["Queries; upload_knowledge", "and the other operator-only",
               "procedures, when the caller is listed"])

    s.element("b-ext", 20, 440, 230, 110, "Other mcl-rag shards", "[External system]",
              ["The org's federated retrieval", "(macula_rag); same model", "and dimension only"])
    s.element("b-ext", 330, 440, 200, 110, "macula-station", "[External system]",
              ["Pinned home station; carries", "every call to and from", "this node"])
    s.element("b-ext", 545, 440, 200, 110, "macula-realm", "[External system]",
              ["Boot identity claim; a D25", "provider grant for each", "procedure"])
    s.element("b-ext", 760, 440, 220, 110, "ollama on msi00", "[External: loopback 11434]",
              ["e5-small embeddings (384)", "and qwen2.5 for topics;", "no key, no hosted LLM"])
    s.element("b-later", 760, 576, 220, 60, "mcl-embedder", "[not used on msi00]", [])

    s.text("t-rel", 143, 170, "uses")
    s.text("t-rel", 857, 170, "uses", anchor="end")
    s.text("t-rel", 686, 100, "admin, on the box:", anchor="middle")
    s.text("t-rel", 686, 124, "HTTP, loopback 8451", anchor="middle")
    s.text("t-rel", 310, 238, "answer_query,", anchor="middle")
    s.text("t-rel", 310, 252, "add_knowledge,", anchor="middle")
    s.text("t-rel", 310, 282, "upload_knowledge", anchor="middle")
    s.text("t-rel", 310, 296, "(over the mesh)", anchor="middle")
    s.text("t-rel", 690, 252, "procedures", anchor="middle")
    s.text("t-rel", 690, 282, "(over the mesh)", anchor="middle")
    s.text("t-rel", 492, 170, "clones, fast-forwards (HTTPS)", anchor="end")
    s.text("t-rel", 145, 410, "asks: rag.query_shard_v1")
    s.text("t-rel", 432, 416, "dials out,", anchor="end")
    s.text("t-rel", 432, 430, "pinned (QUIC)", anchor="end")
    s.text("t-rel", 588, 380, "claims its")
    s.text("t-rel", 588, 394, "identity")
    s.text("t-rel", 753, 392, "embeds,", anchor="middle", rotate=None)
    s.text("t-rel", 753, 406, "classifies", anchor="middle")
    s.write("c4-context.svg")


# ---------------------------------------------------------------------------
# Level 2: containers
# ---------------------------------------------------------------------------
def containers():
    s = Svg(1000, 700, "mcl-rag containers")

    s.bound("bound", 220, 40, 560, 624, "msi00.lab [lab box, rootless podman, host networking]")
    s.bound("bound-in", 236, 72, 528, 476, "mcl-rag [Software system, mcl-om service]")

    # Edges
    s.edge("M200 136H260")                     # macula-mcp
    s.edge("M200 226H260")                     # macula-cli
    s.edge("M200 306H260")                     # other shards
    s.edge("M740 134H810")                     # station
    s.edge("M740 228H810")                     # realm
    s.edge("M740 270H795V395H810")             # corpus repos
    s.edge("M740 300H752V608H740")             # ollama
    s.edge("M335 320V350")                     # data volume
    s.edge("M500 320V350")                     # identity key
    s.edge("M665 320V350")                     # corpus list

    s.element("b-sys", 260, 100, 480, 220, "mcl-rag service",
              "[Container: OCI image, OTP 28 release, mcl_om 0.33.3]",
              ["Eighteen procedures as mcl-rag/<name>, and rag.query_shard_v1",
               "through macula_rag 0.2 (macula 13.0.1). From mcl-om: node",
               "identity, pinned outbound station dial, realm identity claim,",
               "provider grants, mcl-rag/info, /health on 8450.",
               "Local HTTP API on 8451, loopback, no authentication.",
               "Git sync and re-embed loops, every 120 s each.",
               "Storeless for mcl-om: no reckon-db is started."])

    s.element("b-cmp", 260, 350, 150, 120, "Data volume", "[mcl-rag-data]",
              ["/var/lib/mcl-rag:", "barrel rag_chunks,", "corpus/<repo-id>"])
    s.element("b-cmp", 425, 350, 150, 120, "Identity key", "[mcl-rag-secrets]",
              ["/etc/mcl/secrets:", "puzzle-hardened", "node key"])
    s.element("b-cmp", 590, 350, 150, 120, "Corpus list", "[bind mount, ro]",
              ["corpus-repos.json:", "repo ids, URLs,", "branches"])
    s.rect("b-later", 260, 490, 480, 44)
    s.text("t-desc", 276, 517, "reckon-db event store: offered by mcl-om (store_id/0), not used here")

    s.element("b-ext", 260, 568, 480, 80, "ollama",
              "[Container: own Quadlet unit, 127.0.0.1:11434]",
              ["macula/multilingual-e5-small:f16 (384 dims); qwen2.5:7b-instruct-q4_K_M"])

    s.element("b-ext", 10, 96, 190, 80, "macula-mcp", "[MCP server]",
              ["outside the fleet"])
    s.element("b-ext", 10, 190, 190, 72, "macula-cli, lazymesh", "[mesh clients]", [])
    s.element("b-ext", 10, 276, 190, 80, "Other shards", "[mcl-rag, same org]",
              ["federated retrieval"])

    s.element("b-ext", 810, 96, 180, 76, "macula-station", "[pinned seed]", [])
    s.element("b-ext", 810, 190, 180, 76, "macula-realm", "[trust anchor]", [])
    s.element("b-ext", 810, 350, 180, 90, "Corpus repos", "[GitHub, HTTPS]",
              ["no credentials"])
    s.element("b-later", 810, 568, 180, 80, "mcl-embedder", "[unused on msi00]",
              ["embedding over the mesh"])

    s.text("t-rel", 230, 128, "calls", anchor="middle")
    s.text("t-rel", 230, 218, "calls", anchor="middle")
    s.text("t-rel", 230, 298, "asks", anchor="middle")
    s.text("t-rel", 30, 380, "all over the mesh, via the station")
    s.text("t-rel", 775, 126, "dials", anchor="middle")
    s.text("t-rel", 775, 220, "claims", anchor="middle")
    s.text("t-rel", 768, 262, "syncs", anchor="middle")
    s.text("t-rel", 752, 460, "embeds, classifies", anchor="middle", rotate=90)
    s.text("t-rel", 343, 340, "barrel")
    s.text("t-rel", 508, 340, "loads")
    s.text("t-rel", 673, 340, "reads")
    s.write("c4-containers.svg")


# ---------------------------------------------------------------------------
# Level 3: components of the service
# ---------------------------------------------------------------------------
def components():
    s = Svg(1240, 1420, "mcl-rag components")
    s.bound("bound", 16, 40, 960, 1264, "mcl-rag service [Container]")

    s.component("b-sys", 32, 76, 928, 84, "apps/mcl_rag: mcl_rag_service", "[mcl_om_service behaviour]",
                ["Six callbacks. capabilities/0: the eighteen procedures, each mcl-rag/<name> v1 through mcl_om_simple_handler.",
                 "identity_spec/0: scope mcl-rag, no actions or resources, 30 days. No store_id/0 or data_dir/0: storeless."])

    # What mcl-om provides
    s.bound("bound-in", 32, 180, 928, 112, "mcl_om 0.33.3 [library: what every mcl-om service gets]")
    om = [("b-cmp", "identity key", ["/etc/mcl/secrets; the node", "id survives a recreate"]),
          ("b-cmp", "station dial", ["pinned seed + node id;", "{mesh, required} at boot"]),
          ("b-cmp", "realm claim", ["boot claim; a D25 grant", "per procedure"]),
          ("b-cmp", "info, /health", ["mcl-rag/info; /health on", "8450 with grants, liveness"]),
          ("b-later", "event store", ["reckon-db via store_id/0:", "not used by mcl-rag"])]
    for i, (cls, name, desc) in enumerate(om):
        x = 48 + i * 180
        s.rect(cls, x, 208, 168, 68, rx=8)
        s.text("t-code t-small", x + 12, 228, name)
        s.text("t-desc", x + 12, 248, desc[0])
        s.text("t-desc", x + 12, 264, desc[1])

    # The service's own processes (mcl_rag_sup)
    s.bound("bound-in", 32, 312, 928, 236, "apps/mcl_rag [the service's processes, under mcl_rag_sup]")
    s.component("b-cmp", 48, 344, 440, 88, "refresh_corpus_scheduler", "[every 120 s]",
                ["Hashes **/*.md in each checkout. On a change: detect,",
                 "schedule_reembed, upsert_source, embed_document"])
    s.component("b-cmp", 504, 344, 440, 88, "corpus_git_sync", "[every 120 s]",
                ["Rust NIF, vendored libgit2, HTTPS only: clones or",
                 "fast-forwards each repo; a diverged one is left alone"])
    s.component("b-cmp", 48, 448, 290, 88, "mcl_rag_mesh_rpc", "[Router]",
                ["The 17 handlers. rag_operators gate:",
                 "8 procedures need a verified operator"])
    s.component("b-cmp", 354, 448, 290, 88, "HTTP API", "[cowboy, 8451]",
                ["Loopback by default; routes from the",
                 "slices' *_api modules; no operator gate"])
    s.component("b-cmp", 660, 448, 284, 88, "join_federation", "[macula_rag]",
                ["answer_federated_query embeds the",
                 "text locally, searches rag_store"])

    # Desks, left column
    s.bound("bound-in", 32, 568, 456, 376, "apps/embed_corpus [write desks]")
    left = [("add_knowledge", "chunk, embed, store a snippet"),
            ("upload_knowledge *", "upsert a document by id"),
            ("ingest_document *", "upsert a source record"),
            ("embed_document *", "re-chunk, re-embed a document"),
            ("classify_topics *", "topics from local qwen2.5"),
            ("prune_chunks *", "delete chunks"),
            ("retire_document *", "a document and its chunks"),
            ("seed_corpus", "HTTP only: ingest a tree")]
    for i, (n, d) in enumerate(left):
        s.row("b-cmp", 48, 600 + 42 * i, 424, n, d)

    s.bound("bound-in", 32, 960, 456, 166, "apps/query_sources [read desks]")
    for i, (n, d) in enumerate([("get_source_by_id", "one source record"),
                                ("list_sources_page", "sources, paged"),
                                ("get_document_verbatim", "raw bytes, mesh only")]):
        s.row("b-cmp", 48, 992 + 42 * i, 424, n, d)

    # Desks, right column
    s.bound("bound-in", 504, 568, 456, 124, "apps/refresh_corpus [write desks]")
    for i, (n, d) in enumerate([("detect_corpus_change *", "compare, write watermark"),
                                ("schedule_reembed *", "record a re-embed request")]):
        s.row("b-cmp", 520, 600 + 42 * i, 424, n, d)

    s.bound("bound-in", 504, 708, 456, 124, "apps/serve_retrieval [read desks]")
    for i, (n, d) in enumerate([("answer_query", "embed + search; no LLM answer"),
                                ("rerank_results", "0.65 semantic + lexical")]):
        s.row("b-cmp", 520, 740 + 42 * i, 424, n, d)

    s.bound("bound-in", 504, 848, 456, 166, "apps/query_chunks [read desks]")
    for i, (n, d) in enumerate([("search_chunks_semantic", "text or vector, top_k"),
                                ("get_chunk_by_id", "one chunk"),
                                ("list_chunks_by_source", "a document's chunks")]):
        s.row("b-cmp", 520, 880 + 42 * i, 424, n, d)

    s.rect("b-cmp", 504, 1030, 456, 96, rx=8)
    s.text("t-desc", 518, 1062, "* operator-only: refused with not_an_operator unless the")
    s.text("t-desc", 518, 1078, "caller macula verified is in MCL_RAG_OPERATORS. No desk")
    s.text("t-desc", 518, 1094, "emits events; each reads or writes rag_store directly.")

    # The shared store and embedder
    s.bound("bound-in", 32, 1156, 928, 132, "apps/rag [shared store and embedder]")
    s.component("b-cmp", 48, 1188, 440, 84, "rag_store", "[gen_server, barrel]",
                ["One database, rag_chunks: documents, vectors, sources,",
                 "watermarks, re-embed requests. Refuses every call",
                 "with store_opening while the index rebuilds."])
    s.component("b-cmp", 504, 1188, 212, 84, "rag_chunk_embedder", "[Component]",
                ["embeds in the caller's", "process, then writes"], small=True)
    s.component("b-cmp", 732, 1188, 212, 84, "rag_embedder", "[provider choice]",
                ["ollama; mcl_embedder", "exists, unused here"], small=True)

    # External to the container
    s.element("b-ext", 1000, 336, 224, 104, "Corpus repos", "[GitHub, HTTPS]",
              ["deploy/corpus-repos.json,", "cloned under corpus/<id>"])
    s.element("b-ext", 1000, 448, 224, 104, "macula-station", "[pinned]",
              ["carries the 17 procedures", "and rag.query_shard_v1"])
    s.element("b-ext", 1000, 1176, 224, 108, "ollama", "[127.0.0.1:11434]",
              ["e5-small f16, 384 dims;", "qwen2.5 chat for topics"])
    s.element("b-ext", 48, 1336, 440, 64, "Data volume", "[/var/lib/mcl-rag, mcl-rag-data]", [])

    # Edges and labels
    s.edge("M944 388H1000"); s.text("t-rel", 972, 380, "syncs", anchor="middle")
    s.edge("M944 492H1000"); s.text("t-rel", 972, 484, "joins", anchor="middle")
    s.edge("M193 536V568"); s.text("t-rel", 201, 556, "routes, after the gate")
    s.edge("M420 536V568"); s.text("t-rel", 428, 556, "same desks, no gate")
    s.edge("M260 1126V1156"); s.text("t-rel", 268, 1145, "every desk reads or writes rag_store")
    s.edge("M944 1230H1000"); s.text("t-rel", 972, 1222, "embeds", anchor="middle")
    s.edge("M268 1272V1336"); s.text("t-rel", 276, 1320, "rag_chunks and _barrel_system")
    s.write("c4-components.svg")


if __name__ == "__main__":
    os.makedirs(ASSETS, exist_ok=True)
    context()
    containers()
    components()
