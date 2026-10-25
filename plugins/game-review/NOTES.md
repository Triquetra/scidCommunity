# Game review plugin - preservation snapshot

Source of truth: the working plugin folder on the development machine
(`%APPDATA%\scidCommunity\plugins`), copied verbatim on 2026-10-24 so that an
upgrade of the installed scidCommunity cannot lose it.

This branch (`wip/game-review-plugin`) is a **snapshot, not a contribution**.
Nothing here is wired into the build, the install or `tcl/start.tcl`: the files
are an ordinary user plugin and are loaded only when they are copied into a
user folder's `plugins` directory.

## What it is

A self-contained game-review feature for scidCommunity: engine pass, move
labels, accuracy, estimated Elo, key moments, optional coach prose, PGN
writeback, and a "What's the threat?" probe.

| File | Lines | Role |
| --- | --- | --- |
| `09_glist_wheel.tcl` | 171 | game-list wheel speed: N rows per notch, sub-notch accumulation, per-OS bindings |
| `10_cr_board.tcl` | 471 | pure-Tcl board: movegen, make-move, material, SEE, perft |
| `11_cr_classify.tcl` | 617 | label ladder, accuracy, estimated Elo, key moments, phase split |
| `12_cr_settings.tcl` | 77 | settings and `cr_settings.dat` |
| `13_cr_engine.tcl` | 264 | headless MultiPV-3 analysis pass and verifier pass |
| `14_cr_review.tcl` | 765 | pipeline, ECO book boundary, PGN writeback, report text |
| `15_cr_llm.tcl` | 947 | Ollama client, coach prompts, threat probe |
| `16_cr_ui.tcl` | 257 | Tools menu, progress, report window, settings dialog |
| `17_cr_facts.tcl` | 952 | deterministic FACTS lines for the coach prompt |

`tests/` holds the tclsh harnesses used during development (stubbed
`sc_game`/`sc_pos`/`sc_engine`): `harness.tcl` and `compare.tcl` for the review
modules, `glist_wheel_harness.tcl` for the wheel plugin. They are development
assets, not installed with the plugin.

`docs/phase-definitions.md` records why the opening/middlegame/endgame split is
defined the way `11_cr_classify.tcl` defines it.

## Licence

The plugin files carry no copyright header because they were developed as a
private user plugin. Before any of this is published:

- `11_cr_classify.tcl` is a port of Patzer's `server/src/chess/classifier.ts`,
  `accuracy.ts` and `keyMoments.ts` (Patzer, MIT, (c) Arsen Apostolov and
  contributors). `10_cr_board.tcl`'s SEE and `17_cr_facts.tcl`'s motif pass
  derive from the same project. Those files need the MIT notice and licence
  text attached, plus `SPDX-License-Identifier: GPL-2.0-or-later` to match the
  rest of this repository.
- `09_glist_wheel.tcl`, `12_cr_settings.tcl`, `13_cr_engine.tcl`,
  `14_cr_review.tcl`, `15_cr_llm.tcl` and `16_cr_ui.tcl` are original work.

## Known state and what comes next

- Six improvements were taken from the modules upstream already ships (see the
  README sections for the settings): the opening-book probe replaces the ECO
  boundary, a lichess cloud pre-pass fills what the engine would otherwise
  search, model prose is normalised (SAN repair, markdown stripped), the model
  field lists what the endpoint offers, an ECO code can supply an opening name
  when the PGN has no Opening tag, and an opt-in database line adds tree
  statistics to the coach facts.
- Verification: `tests/harness.tcl` (pipeline, verifier, book boundary,
  cloud-prefilled run) and `tests/features.tcl` (unit tests for the six grafts)
  both pass in `tclsh`; the plugin also loads cleanly under
  `plugin-loadtest.tcl`. Neither harness runs the GUI, so dialog layout and
  menu placement still need one manual run.
- `cr_settings.dat` (runtime settings, may hold an API key) and the `*.log`
  files are deliberately **not** in this snapshot.
- Upstream `whelanh/scidCommunity` already ships `auto_comment.tcl` (LLM
  commentary via Gemini/DeepSeek), `analysis_auto_comment.tcl`,
  `rapid_annotate.tcl`, `batch_annotate.tcl` and `accuracy.tcl`. Any future
  contribution has to extend those modules rather than duplicate them; the
  work here that is genuinely absent upstream is the wheel handling, the ECO
  first-exit book boundary, MultiPV move grading, the verifier pass, the threat
  probe and the local-model provider.
