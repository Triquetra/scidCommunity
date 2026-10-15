# Agent notes

## XERJ (code search)

This project uses XERJ for reference coding. Before writing code that touches
unfamiliar territory: `xerj def "<symbol>"` for go-to-definition, or
`xerj search "<plain words>"` for ranked, definition-first passages.
Index a repo with `xerj autoindex <folder>`. Cite file:line for anything you rely on.

A local node at `http://localhost:9200` has two corpora indexed:

- `scid-*` — **this repository's** source (179 code files + docs).
- `ref-*` — **peer chess projects**:
  `ref-stockfish-*` (C++ engine), `ref-scidvspc-*` (Scid vs. PC sibling),
  `ref-scid-codeberg-*` (Codeberg scid fork, indexed in place from
  `~/Downloads/scid`), `ref-chessx-*` (database GUI),
  `ref-pychess-*` (PGN/FEN/engine/tablebases), `ref-cutechess-*` (engine tournaments).

Retrieve a mechanism from a peer before re-deriving it. Full setup, query
recipes and licence/limits notes: **`docs/REFERENCE_CODING.md`**.
