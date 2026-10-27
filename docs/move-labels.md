# Move labels

`tcl/tools/move_labels.tcl` turns the engine evaluations around a move into the
word a reader expects: **best**, **excellent**, **good**, **inaccuracy**,
**mistake**, **blunder**. It is the decision layer between a score and a
comment; nothing here searches or calls an engine, the caller supplies the
evaluations.

```
::movelabels::label   0 -300          -> blunder
::movelabels::game    {0 0 0 0 0 -300 -300}   -> excellent excellent excellent excellent blunder excellent
::movelabels::text    blunder          -> the translated word
```

## Why win percentage, not centipawns

Losing two pawns in a level position and losing two pawns in an already won one
are different mistakes, and the same centipawn loss means different things at
different points on the curve. The ladder is therefore measured on the
win-percentage curve, and that curve is the one the rest of the tree already
uses: `::accuracy::winPercent` in `tcl/tools/accuracy.tcl`. The module loads
that file when it is not loaded yet (the engine window otherwise sources it on
first use) rather than keeping a second copy of the formula, so a label and the
accuracy number displayed beside it cannot disagree about the same move.

The thresholds, from Patzer's classifier (MIT):

| Label | Rule |
| --- | --- |
| best | the move the engine chose |
| excellent | win% drop < 2 **and** centipawn loss < 50 |
| good | win% drop < 5 **and** centipawn loss < 100 |
| inaccuracy | win% drop < 10 |
| mistake | win% drop < 20 |
| blunder | anything larger |

The centipawn guard on the two best labels is what stops a half-pawn loss in a
won position from being called excellent.

## Refinements

The six labels read one score pair. Five more read what the move did to the
board and what the engine's other lines were, and are the vocabulary a reader
actually learns from:

| Label | Rule |
| --- | --- |
| forced | only one legal move — not a choice, whatever it costs |
| book | inside the opening (`ply <= 12` by default, `in_book` overrides) and not a mistake |
| brilliant | the engine's move, out of book, keeps the game (`cp_before <= 500`, `cp_after >= -50`, `cp_loss <= 20`), gives up two points or more that the line does not simply trade back |
| great | the best move beats the second-best by 200cp or more and the position is still playable — or a rescue from `-150` to `-50`; never for taking a piece the opponent left hanging |
| miss | already an inaccuracy, mistake or blunder, and it gave up a win: `cp_before >= 150` and `cp_after < 50`, or a mate was there and is gone |

A board loss of 300cp or more with a win-chance drop of 12 or more is a blunder
even when the curve rounds under the line: near the ends of the curve the two
scales disagree, and the board loss is the fact that does not move.

`::movelabels::refine {label ctx}` takes the base label and a dict:

| Key | Meaning |
| --- | --- |
| `is_best` | the engine chose this move |
| `cp_before`, `cp_after` | evaluations from the mover's view, mate-encoded |
| `cp_loss`, `win_drop` | `::movelabels::cpLoss` / `winDrop` of the two |
| `ply`, `legal_moves`, `in_book` | position context |
| `candidates` | the engine's top evaluations from the mover's view, best first (MultiPV) |
| `played`, `fen_before`, `fen_after`, `pv_after_played` | the move and the board, for the sacrifice and free-capture tests |

The two board questions come from `::chessboard::hangingMaterial` (what the move
left en prise, net of what it took), `::movelabels::isFreeCapture` (a capture the
opponent handed over) and `::movelabels::isTrivialRecapture` (the line simply
trades back).

## Mate

A mate is encoded with `::movelabels::mateToCp` at ±100000 (minus 100 per move
of distance, with the distance clamped so every mate stays outside
`MATE_CP_THRESHOLD`), far outside any score a search can return — Stockfish
reports tablebase wins as centipawns in the thousands, so "a big number means
mate" would misread them. Distance 0 is UCI's `mate 0`, the side to move already
mated, and encodes as the largest loss for that side: the move that delivered
the mate is a win of 100% for the mover, and being mated is the largest drop
there is.

## Using it

| Proc | Purpose |
| --- | --- |
| `label {before after {isBest 0}}` | one move, both scores from the mover's point of view |
| `game {cps {bestPlies {}}}` | a whole game from one evaluation list (White's view, as `::accuracy::calculate` takes it), judging each ply from its own player's side |
| `forMover {cp mate stm mover}` | an engine score (side to move's view) as the mover sees it |
| `winDrop`, `cpLoss` | the two measurements the ladder is built on |
| `mateToCp`, `isMate` | the mate encoding |
| `refine {label ctx}` | the refined label, from what the move did and the engine's other lines |
| `isFreeCapture {fen uci}` | takes a piece standing there for free |
| `isTrivialRecapture {side fen pv fenAfter}` | the line simply trades back |
| `text {label}` | the translated word for display |

## Translation

The labels returned by `label` are identifiers: what a PGN, a report or a test
stores, and they do not change with the UI language. The words a reader sees
come from `::movelabels::text`, which looks up `MoveLabel<Label>` in
`tcl/lang/*.tcl` — eleven keys, from `MoveLabelBest` to `MoveLabelBook`. A language file
that has not been updated yet still shows the English word through `tr()`'s
fallback to the English table.

## Tests

`tclsh tests/tcl/move_labels.tcl` (also run by the Tcl Tests workflow). The
table pins every boundary of the ladder from both sides together with the drop
it computes (1.93 points still excellent, 2.02 not; 4.95 good, 5.05 inaccuracy;
9.99 inaccuracy, 10.08 mistake; 19.99 mistake, 20.76 blunder), a property check
asserts that a bigger loss never earns a better label, and the mate transitions
are covered separately.

## Related

- `docs/comment-facts.md` — the deterministic facts a comment is allowed to
  state, from `tcl/tools/comment_facts.tcl`.
