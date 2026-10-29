# The engine window's review buttons

The engine window used to carry one **Game Comment** button that opened the
batch annotator. It now carries two buttons over one engine pass, plus a small
settings dialog. The pass itself is `::reviewdriver` (`tcl/tools/review_driver.tcl`),
the decisions behind the buttons are `::reviewui` (`tcl/tools/review_ui.tcl`),
and what a finished pass writes into the game is the writeback slice that
follows — the buttons here start the pass and report it, they do not annotate.

```
[Game Review]  [Move Comment]  [Review Settings]  [Cancel]   Reviewing position 3 of 42
```

Both buttons are disabled unless there is a game with moves and an engine; Move
Comment additionally needs a move after the current position, and both are
disabled while a pass runs, which is what Cancel is for.

## Game Review — the whole main line

Press **Game Review** and the pass searches every position of the main line at
the review's depth, showing `Reviewing position n of m` in the button bar.

The positions come from `::review::searchPlies` over the snapshot
`::review::mainLineMap` takes of the line, so:

- the board is never moved to build a position, and the pass is unaffected by
  where the user has scrolled to;
- the reference position for each planned move is searched, plus the position
  after the last move, so the last move can still be judged when it is not one
  of the engine's lines;
- a null move appears as a fresh `position … moves` header in that snapshot and
  does not shift the plies after it.

Which plies are planned is `::review::plan`: with book skipping on it starts one
position before the game leaves the book, so the move that leaves it has the
reference position it needs. This window passes `bookEnd 0` — the whole line —
because asking a book where the game leaves it would be a search of its own
before the first one.

Depth and MultiPV are **not** settings of the review dialog: they come from
`::review::effective`, where the engine preset wins `Threads`, `Hash` and a
higher `MultiPV`, and the review's own depth is a floor a shallower preset cannot
lower.

The pass runs on its own engine connection (id 20), so it never restarts the
search the user is watching in the analysis pane.

**Cancel** stops the pass: no further position is started, the engine is closed
and nothing is written.

## Move Comment — the current move only

Press **Move Comment** to judge the move played from the current position. It
searches two positions, the one before the move and the one after it, because a
verdict needs both scores: what the move was worth, and what it brought.

When it may start is `::review::moveCommentPlan`:

- with `move_comment_wait` on (the default) the comment has to be the one a
  review would have written, so a shallower analysis is not good enough: the pass
  searches at the review's depth, and the bar says `Waiting for depth 18` until
  it gets there. That depth is the *effective* one (`::review::effective`): an
  engine preset with its own deeper limit raises it, so a review and a one-move
  comment of the same position cannot disagree at two depths;
- with `move_comment_wait` off, whatever the window's own analysis has already
  reached is good enough, and nothing waits — the depth shown in the bar's depth
  box is the depth used.

The current analysis depth is read from the window's depth map, the one the
Autorun pass fills in. A position that has not been analysed yet has no entry,
and that is "nothing yet", not "depth 0".

## Review Settings

**Review Settings** opens five rows:

| Row | Setting | Range |
| --- | --- | --- |
| Lines | `mpv` | 1–5 |
| Depth | `depth` | 6–60 |
| Variations to write | `var_lines` | 0–`mpv` |
| Variation margin (cp) | `var_cp` | 0–500 |
| Wait for the review depth | `move_comment_wait` | 0–1 |

Every row is stored through `::review::setValue`, which owns the rules. A value
it refuses is reported in the dialog and the dialog stays open, so the rest of
the edit is not lost; nothing is clamped behind the user's back. `var_lines` is
capped by `mpv`, so its box follows `mpv` rather than offering a number the
setter would reject.

**Threads and Hash are not in this dialog.** They are properties of the engine
preset — the whole point of the preset work in #382 — and are set from the
window's own controls. The dialog shows them read-only, under the five rows, as
`Threads 8, Hash 256 MB (from engine preset)`. A second place to set them is a
second place to get them wrong, and the window's own controls already write the
preset.

## What the buttons do not do

They do not write anything into the game. A finished pass leaves its results in
`::enginewin::reviewresults($id)`, keyed by ply, in the driver's shape:

```
dict ply -> dict multipv -> {depth score score_type pv}
```

Turning those into move labels, `[%eval]` tokens and gated variations is
`::review::writeMove` (already merged) driven by the writeback slice. Keeping the
search and the write apart is deliberate: writing mid-pass re-enters the engine
window from an open engine, which makes the main-line snapshot non-authoritative.

## Files

| File | What is there |
| --- | --- |
| `tcl/tools/game_review.tcl` | `::review` settings, `plan`, `searchPlies`, `mainLineMap`, `playedMove`, `moveCommentPlan`, `writeMove`, `selectLines` |
| `tcl/tools/review_driver.tcl` | `::reviewdriver` — the engine pass on connection 20 |
| `tcl/tools/review_ui.tcl` | `::reviewui` — button state, plan→spec mapping, dialog values, status lines |
| `tcl/windows/engine.tcl` | the two buttons, the status line, the settings dialog (guarded glue) |
| `tests/tcl/review_ui.tcl` | 153 checks: the mapping, the button states, the dialog round trip, the move-comment depth, the key set |

## Tests

`tclsh tests/tcl/review_ui.tcl` (also run by the Tcl Tests workflow) pins what a
widget would otherwise have to decide:

- **the plan → spec mapping** against `::review::searchPlies` and
  `::review::mainLineMap`, including a null move in the middle of the line, a
  shortened plan, and a position the map cannot name;
- **button state** for every combination the window can be in — no game, no
  engine, last position, a pass running, and a state dict with a key missing;
- **the dialog round trip**: read, change, refuse one field, and check the four
  good fields still landed and the refused one kept its old value, with the
  spin-box ranges checked against what `::review::setValue` accepts;
- **the one-move depth**, from `moveCommentPlan`, for a deep analysis, a shallow
  one, nothing analysed, the wait turned off, and a preset that raises the depth
  the review would use;
- **the key set**: the twelve new strings are present in all 29
  `tcl/lang/*.tcl` files, the file list is read from the tree so a new language
  file fails loudly, and the English text is the text the labels are asserted
  against.

The Tk glue in `tcl/windows/engine.tcl` is guarded rather than tested: a missing
widget, a missing engine or a driver that refuses to start is a no-op with a
message, never an exception in the middle of a game.

## Related

- `docs/move-labels.md` — the label ladder the comments are built on.
- `docs/engine-presets.md` — the presets that own Threads, Hash and the search
  limits.
- `docs/comment-facts.md` — the deterministic facts a comment may state.
