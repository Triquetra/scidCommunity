# Reference coding with XERJ

This project has a local [XERJ](https://xerj.org) node with two searchable
corpora: **this repository** and a set of **peer chess projects**, cloned and
indexed so an agent can retrieve how a neighbouring project already solved a
problem *before* writing code.

The workflow (the measured "reference coding" loop):

1. **Retrieve** the mechanism from an indexed peer (`xerj search` / the
   `xerj_search` MCP tool) and read the returned passage with its `file:line`.
2. **Adapt** it to this codebase and **cite** the source you relied on.
3. If nothing relevant comes back, say so and work normally — a forced match is
   worse than no retrieval.

## The node

| | |
| --- | --- |
| Endpoint | `http://localhost:9200` (Elasticsearch 8.x-compatible) |
| Data dir | `~/xerj-data` (kept **outside** every indexed tree) |
| Start | `nohup xerj --insecure --data-dir ~/xerj-data > ~/xerj-node.log 2>&1 & echo $! > ~/xerj-node.pid` |
| Health | `curl -s localhost:9200/_cluster/health` |
| Stop | `kill $(cat ~/xerj-node.pid)` — only a node you started; never `pkill xerj` |

> **Embedding mode is fixed at ingest.** The node runs in the **default lexical
> mode** (deterministic feature-hashing, BM25-style). This is the configuration
> the reference-coding study measured. Neural mode (`--embed-mode neural`) would
> require re-indexing every corpus, so decide before re-indexing if you want it.

## The corpora

**This project** — prefix `scid`, query `scid-*` (7 indices, ~28.5k records;
179 C/C++/Tcl source files).

**References** — prefix `ref-<repo>`, query all with `ref-*` or one repo with
`ref-<repo>-*`. Peers are cloned into `~/xerj-refs/` (shallow, pinned to the
commit below); the Codeberg `scid` fork is indexed **in place** from
`~/Downloads/scid`. State/journals live in `~/xerj-state/`.

> **Index-name patterns take a trailing `*` only.** `ref-*` and `ref-pychess-*`
> work; `ref-*-docs` matches nothing. To restrict a query to source files, use a
> per-repo pattern (`ref-pychess-*`) or add a `{"term":{"ax_format":"code"}}`
> filter.

| Prefix | Upstream | Commit | Licence | Records | Why it is here |
| --- | --- | --- | --- | --- | --- |
| `ref-stockfish` | official-stockfish/Stockfish | `5c4cef0` | GPL-3.0 | 1,469 | Canonical C++ engine: bitboards, `attacks.h`-style move generation, UCI protocol, search/eval, EPD |
| `ref-scidvspc` | benini/scid (Scid vs. PC) | `fc26337` | GPL-2.0 | 10,054 | Closest sibling — a Tcl/Tk `scid` fork with the same `dbase`/`codec`/`movetree`/`polyglot` lineage |
| `ref-scid-codeberg` | codeberg.org/scid/scid (branch `myscid`) | `be2908ea` | GPL-2.0 | 10,589 | The fork this project credits for the engine-vs-engine tournament feature and PGN viewer; same `scid` core, indexed in place from `~/Downloads/scid` |
| `ref-chessx` | Isarhamster/chessx | `e734a07` | GPL-2.0 | 8,333 | Peer chess database GUI: PGN import/export, filters, database backends |
| `ref-pychess` | niklasf/python-chess | `0c6bdac` | GPL-3.0 | 10,639 | Reference for PGN/SAN/FEN parsing, move legality, polyglot books, UCI/engine, Syzygy tablebases |
| `ref-cutechess` | cutechess/cutechess | `5e84232` | GPL-3.0 | 9,396 | Engine-vs-engine tourneys, UCI/XBoard engine management, PGN game records |

All six peers are GNU GPL; this project is GPL too, so the licences are
compatible. Still follow the reference-coding rule for GPL peers: **read the
design and adapt it — do not paste code**, and record which file:line you used.

## Retrieving

Definition-first query (ranks the file that *defines* a symbol above files that
merely mention it; `_passage` returns the enclosing function/block, not the whole
file):

```sh
curl -s 'http://localhost:9200/ref-*/_search' -H 'Content-Type: application/json' -d '{
  "query":{"bool":{"should":[
    {"multi_match":{"query":"<symbol or plain words>","fields":["body","defs"],"type":"most_fields"}},
    {"match_phrase":{"defs":{"query":"<symbol or plain words>","boost":4}}}]}},
  "_source":["ax_path","title"],"fields":["_passage"],"size":5}'
```

Scope it: replace `ref-*` with `ref-stockfish-*` (engine internals),
`ref-pychess-*` (formats/protocol), `ref-scidvspc-*` or `ref-scid-codeberg-*`
(the two sibling `scid` forks), `ref-chessx-*`, or `ref-cutechess-*`; use
`scid-*` for this project's own code.

CLI and MCP shortcuts:

```sh
xerj search "how the movetree encodes variations"   # ranked passages, definitions first
xerj def "scidMove"                                 # go-to-definition: file:line + signature
```

MCP tool `xerj_search` takes the same plain-string query. `xerj_map` returns each
index's real field names/types — call it before writing query DSL.

## Honest limits

- **Lexical, not neural.** Query in the words the source would use; a paraphrase
  that shares no words will miss. (Neural is opt-in via `--embed-mode neural`,
  at the cost of re-indexing.)
- **Definitions only.** Hits name the declaration site; there is no call graph,
  no import graph, no cross-file reference resolution.
- **Retrieval pays on unfamiliar code, not memorised libraries.** Stockfish's
  `attacks`/`movegen` are widely known — for those, retrieval is often overhead.
  It pays most on this project's own internals and on niche peer code.
- **Server memory grows with documents indexed.** Index one corpus at a time and
  watch `ps -o rss= -p $(cat ~/xerj-node.pid)`; restarting with the same
  `--data-dir` keeps every index and releases heap.

## Re-indexing / adding a peer

```sh
git clone --depth 1 <url> ~/xerj-refs/<name>
xerj autoindex ~/xerj-refs/<name> --prefix ref-<name> --state-dir ~/xerj-state/ref-<name> --progress plain
```

`autoindex` is idempotent (a re-run resumes and never duplicates). Exit code `3`
means *completed with junk* and is a **success** (binary assets skipped).
