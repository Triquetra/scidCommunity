# How chess phases are defined — and how our plugin's definition compares

**Question:** the review plugin splits a game into opening / middlegame / endgame.
Is our rule (book end floored at 12 plies; endgame on non-pawn material) defensible
against how the rest of the chess world and open-source projects define the same
boundaries?

Every claim below is cited to the source that owns it.

---

## 1. What chess literature says

There is no agreed criterion. Wikipedia's *Chess endgame* article opens its
"The start of the endgame" section with that admission and quotes Alekhine:
"We cannot define when the middle game ends and the endgame starts."
(<https://en.wikipedia.org/wiki/Chess_endgame>)

The competing definitions it records:

| Author | Endgame begins when | Type of test |
|---|---|---|
| Fine | there are no queens | piece identity |
| Speelman | each player has ≤ 13 points of material, king excluded | material points |
| Flear | **both** players have at most one piece other than kings and pawns | piece count |
| Dvoretsky | **at least one** player has at most one such piece | piece count |
| Minev | four or fewer pieces other than kings and pawns | piece count |
| Alburt & Krogius | king becomes aggressive, passed pawns dominate, zugzwang matters | positional traits |
| Mednis & Crouch | *not* an endgame if: better development, open files for attack, vulnerable king, misplaced pieces | negative / positional |

Two things follow. First, every published criterion is **material- or
development-based**, not time- or theory-based: nobody defines the endgame by
move number. Second, the only widely quoted *points* threshold — Speelman's
13 each — equals **26 non-pawn points for both sides combined**, which is
exactly the number our implementation uses.

The opening end is treated differently again: it is defined by **development
and king safety** (the classical opening tasks), not by a move count, and
Mednis & Crouch's negative test says a position with "better development" or a
"vulnerable king" is not an endgame — i.e. development is what distinguishes
middlegame from endgame.

## 2. What engines do

The Chess Programming Wiki, *Game Phases*
(<https://chessprogramming.org/Game_Phases>): the textbook three-way division
"is good enough for humans, [but] coding it in a straightforward manner would
introduce evaluation discontinuity in many places. For that reason many programs
define several game phases, based on the amount of material on the board."

So engines do not segment games for a reader at all — they interpolate between
midgame and endgame evaluation tables by material. Their "phase" is an
evaluation weight, not a review boundary; it is not a model for us.

## 3. What lichess does (the only open-source, review-facing implementation)

`scalachess/core/src/main/scala/Divider.scala`
(<https://github.com/lichess-org/scalachess/blob/master/core/src/main/scala/Divider.scala>)
exports `Division(middle, end, plies)` and is the code behind lichess's
opening / middlegame / endgame split. The rule, verbatim from the source:

```scala
val midGame = indexedBoards.collectFirst:
  case (board, index)
    if (majorsAndMinors(board) <= 10 || backrankSparse(board) || mixedness(board) > 150) =>
    index

val endGame =
  if midGame.isDefined then
    indexedBoards.collectFirst:
      case (board, index) if majorsAndMinors(board) <= 6 => index
  else None
```

with

```scala
private def majorsAndMinors(board: Board): Int =
  (board.occupied & ~(board.kings | board.pawns)).count          // piece count, both sides

private def backrankSparse(board: Board): Boolean =
  (Bitboard.firstRank & board.white).count < 4 ||
  (Bitboard.lastRank & board.black).count < 4                    // development test
```

plus `mixedness`, a spatial score over 7x7 regions that detects entangled,
closed positions.

Three properties matter for us:

1. **The opening ends on a position, not on theory.** The trigger is "fewer
   than four of my pieces are still on my back rank", i.e. development — the
   classical opening task. In practice this fires around moves 6-10.
2. **The endgame is a piece count, not points**: six majors-and-minors
   remaining, total. (Six pieces averaging ~4 points each ≈ 26 points, so this
   and Speelman converge.)
3. **The phases can never overlap or invert.** `endGame` is only computed if
   `midGame` exists, and the middlegame start is filtered with
   `m < endGame` before being stored.

## 4. What our plugin does

`11_cr_classify.tcl`, `::crclass::phaseSplit` (ported from Patzer's
`computePhaseSplit`, `server/src/routes/analyze.ts`):

```tcl
set openingTo [expr {min($total, max(12, $bookPlies))}]   ;# book end, floored at 12 plies
# endgame: first ply where non-pawn material <= 26 AND (queens off OR npm <= 16)
set middleFrom [expr {$openingTo + 1}]
set middleTo   [expr {min($total, $endgameFrom - 1)}]
```

and a bucket shorter than four plies produces no paragraph at all.

---

## 5. Comparison

| Property | Literature | lichess | ours |
|---|---|---|---|
| Opening ends | development + king safety | first board with a sparse back rank, or ≤10 majors/minors, or high mixedness | **end of ECO book, floored at 12 plies** |
| Endgame starts | 26 points (Speelman) / no queens (Fine) / ≤4 pieces (Minev) / ≤1 piece (Flear, Dvoretsky) | ≤6 majors-and-minors (piece count) | **npm ≤ 26 and (queens off or npm ≤ 16)** |
| Uses the opening book | no | no | **yes** |
| Guarantees ordered, non-overlapping phases | n/a | yes, by construction | **no** |
| Minimum phase length | n/a | none (may return `None`) | 4 plies |

### What we get right

- The 26-point threshold is Speelman's, and it is applied to the same quantity
  (non-pawn material, both sides).
- The "queens off" alternative is Fine's definition, so the endgame branch has
  two textbook parents rather than an invented number.
- Our book detection (`firstExitPly`, per-prefix `sc_game eco ply`) is stricter
  than anything in lichess: it closes the transposition hole where a game
  leaves theory and re-enters it.

### What is wrong or indefensible

1. **Phase overlap — a real bug.** `openingTo` is computed independently of
   `endgameFrom`, so a game that reaches endgame material before ply 12 is
   counted in both phases. Measured on a synthetic game whose endgame
   threshold is met at ply 9:

   ```
   opening     plies 1-12
   middlegame  (none)
   endgame     plies 9-20
   overlapping plies: 9, 10, 11, 12
   ```

   Lichess cannot produce this: the endgame is only defined when the
   middlegame exists, and the middlegame is filtered to start before it.
   Patzer has the same defect we inherited.

2. **The 12-ply floor is a constant with no chess meaning.** It exists so a
   3-move game still gets an "opening" paragraph. Consequence: a game that
   leaves book at move 7 still has an opening phase running to move 12, and
   the paragraph is written about plies that are no longer theory. In the test
   game the book ended at ply 7 and the opening still claimed 12.

3. **The opening boundary is theory-driven, not position-driven.** A player who
   deviates at move 4 into a non-book middlegame position is still "in the
   opening" by our rule; a player who follows a 25-ply theoretical line has an
   opening twice as long as their opponent's. Chess literature and lichess both
   treat this as a property of the position (development), not of the book.

4. **The endgame branch is stricter than every published rule in one direction
   and looser in another.** Requiring `queens off OR npm ≤ 16` in the 17-26
   band means a queenless 30-point position is not an endgame for us, though
   Fine would call it one. Conversely `npm ≤ 16` (8 points each) is *later* than
   Flear's one-piece rule in some positions and *earlier* in others.

---

## 6. What was implemented (supersedes the recommendation below)

The boundary rule now in `11_cr_classify.tcl`:

- **opening -> middlegame**: first ply where the ECO book has ended **and** any
  lichess positional signal fires (`majors+minors <= 10`, a back rank with
  fewer than four own pieces, or `mixedness > 150`). Both must agree, so a game
  still in theory stays in the opening, and a win that comes from leaving book
  is still filed under the opening.
- **middlegame -> endgame**: only if the middlegame exists and starts earlier;
  the first ply where (`<= 26` points on the board counting pawns, kings
  excluded, **and** queens off) **or** `majors+minors <= 6`. Disjoint and
  ordered by construction.
- `mixedness` is a faithful port of lichess's 2x2-window scoring.

Measured on the test game (Crandall-McAfee, book ended at ply 7):

```
ply   1-9    majors 14   sparse 0   mixedness 36-84
ply  10-19   majors 12-13
ply  20-21   majors 11-10        <- middlegame starts at ply 21 (move 11)
ply  27-31   mixedness crosses 150 (never sparse before ply 29)
```

so: opening 1-20, middlegame 21-31, no endgame, no overlap. The two blunders
(8...f5, 9...Qxe4) fall inside the "opening" phase for this game. That is the
rule's intent — the game never became a middlegame by material or development —
but it is worth re-examining if opening paragraphs start carrying decisive
errors. The threshold lever is the majors figure: `<= 12` would move this
game's middlegame to ply 11, `<= 11` to ply 20.

## Sources

- Wikipedia, *Chess endgame*, "The start of the endgame" — Fine, Speelman,
  Flear, Dvoretsky, Minev, Alburt & Krogius, Mednis & Crouch, Alekhine quote.
  <https://en.wikipedia.org/wiki/Chess_endgame>
- Chess Programming Wiki, *Game Phases* — engines define phases by material to
  avoid evaluation discontinuity. <https://chessprogramming.org/Game_Phases>
- lichess `scalachess`, `Divider.scala` — the actual rule and its guards.
  <https://github.com/lichess-org/scalachess/blob/master/core/src/main/scala/Divider.scala>
- Patzer, `server/src/routes/analyze.ts`, `computePhaseSplit` — the source of our
  current rule (local copy of the project).
- Our plugin, `11_cr_classify.tcl`, `::crclass::phaseSplit` (local).
