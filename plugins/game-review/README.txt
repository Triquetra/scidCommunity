scidCommunity game review plugin
=================================

Chess.com-style game review, computed locally, written into the PGN.

WHAT IT DOES
  * move labels: Brilliant / Great / Best / Excellent / Good / Book /
    Forced / Inaccuracy / Mistake / Miss / Blunder
  * accuracy % per side (CAPS-style: volatility weighted + harmonic blend)
  * estimated Elo per side, and a performance rating when the PGN carries
    the opponent's rating
  * key moments (3-5, ranked like chess.com's highlight reel)
  * optional coach prose (Ollama) on the key moments and as a game summary
  * "What's the threat?" for the position on the board

USAGE
  Tools -> Game review -> Game review            (annotates the current game)
  Tools -> Game review -> What's the threat?     (asks about the board position)
  Tools -> Game review -> Review settings...     (engines, depth, coach)

  The game must be saved in a writable database and you must be on the main
  line (not inside a variation). Annotations are written to the PGN; Ctrl+Z
  undoes the whole pass.

ENGINE SETTINGS (applied in config/engines.dat)
  All four engines are configured for 8 threads (the machine has 8 cores /
  16 logical) and 1024 MB hash, Syzygy paths for every table directory, and
  their own working directory set — RubiChess will not search at all unless
  its folder (with the .nnue) is the cwd.
  The review pass uses the same threads/hash from the plugin settings, so
  changing them there is enough for the review; engines.dat matters for the
  F2/F3 engine windows and the analysis window.

ENGINES
  Two engines are used, both chosen by name from scid's own engine list
  (Tools -> Manage engines), never by path:

    Analysis engine   one MultiPV-3 search per position, depth = setting.
                      Use Stockfish: the thresholds were calibrated against
                      Stockfish evals, and a different engine shifts labels.
    Verifier engine   must be a *different* engine. It re-searches only the
                      moves that would be labelled Brilliant or Great, at
                      depth+4, and withdraws the upgrade when it disagrees on
                      the best move (or does not see an only-good-move gap).

  With the four engines installed here that means Stockfish 19 for analysis
  and Berserk 14 (or RubiChess) for verification. If both boxes name the same
  engine the verifier is skipped.

  Neither uses the F2/F3 engine windows; the plugin opens its own sessions.

BEST LINES
  By default the engine's best line is written as a real PGN variation after
  the played move, so you can step through it on the board. Length is the
  "Best line in comment (plies)" setting (default 5, 0 = off). Only moves
  that differ from the engine's choice and were labelled inaccuracy, mistake,
  miss or blunder get a variation — anything else would just repeat the game.
  An existing variation at the same point is left alone, so re-running the
  review does not stack duplicates.
  Untick "Best line as a variation" to get the line in the move comment
  instead ("[Blunder] -3.00, best Nf5 exd5 Nxd4 [%eval -3.00]").

PGN OUTPUT
  Every move with a quality gets its NAG (!! ! ?! ? ??), plus a bracketed
  label comment, e.g.

    13. c3??  {[Blunder] -3.00, best Nf5 [%eval -3.00]}

  Best/Excellent/Good/Book moves get no NAG and, by default, no comment
  (turn that on in settings). [%eval] tokens are written so scid's score
  graph redraws from the PGN.

  Where the coach's text lands:

    header comment (ply 0)  the game review (accuracy, estimated Elo, label
                            tally), the game summary, the opening line and the
                            level line - everything that is about the whole
                            game
    end of each phase       [Phase opening] / [Phase middlegame] /
                            [Phase endgame], then that phase's plies, accuracy
                            and acpl, then its paragraph. The last phase sits on
                            the game's last ply. Each block is replaced, not
                            stacked, when the same game is reviewed again.

  Phase boundaries come from the position (material, back rank, pawn
  structure), never from the opening book, so which book is installed cannot
  move a paragraph from one phase to another.

COACH (Ollama)
  Set endpoint, API key and model in Review settings.
    local Ollama:      http://localhost:11434   (no key)
    Ollama Cloud:      https://ollama.com       (key required)
  Model names differ between local and cloud: list them with
    curl -H "Authorization: Bearer $KEY" https://ollama.com/v1/models
  The model only writes prose from facts the plugin computed. It never
  decides a label.

FILES
  10_cr_board.tcl     board core: movegen, make-move, material, SEE
  11_cr_classify.tcl  labels, accuracy, Elo, key moments, phase split
  12_cr_settings.tcl  settings + cr_settings.dat
  13_cr_engine.tcl    headless MultiPV passes (ids 20 and 21) and the cloud pre-pass
  14_cr_review.tcl    pipeline, writeback, report text
  15_cr_llm.tcl       Ollama client and prompts
  16_cr_ui.tcl        menus, progress, report, settings dialog
  17_cr_facts.tcl     FACTS lines for the coach, ECO names, database line

  Plugins are executable Tcl with full privileges; keep this folder private.

BOOK PLIES ARE NOT SEARCHED
  The engine pass starts at the book boundary: positions up to the last ECO
  match are never searched, because those moves are labelled Book anyway.
  For a 40-ply game whose theory ends at ply 12 that is 5 searches instead of
  41. A move that *leaves* theory sits beyond the boundary, so it is still
  analysed and can still be labelled a blunder.
  Known limit: scid reports the *deepest* ECO match, so a game that
  transposes back into theory gets a later boundary and the plies in between
  are labelled Book without being analysed. The log prints the boundary, and
  "Skip engine analysis of book plies" turns the whole thing off.
  Book plies get no [%eval] token, so the score graph starts where the
  analysis does.

BOOK DETECTION
  Default is the opening book itself: the plugin asks sc_book which moves the
  book offers at each position and stops at the first ply whose played move is
  not in it. A book is keyed on the position, so a game that leaves theory and
  transposes back in is still judged per ply - no boundary, no over-extended
  "Book" run. Book file: Review settings -> Opening book file (the books that
  ship with scidCommunity are offered; Browse... takes any Polyglot .bin).
  Falls back to the ECO probe when no book file is readable or the book cannot
  be loaded, and to the "Book plies" setting when there is no ECO match either.
  The log prints which source was used:
      book: source=book first non-book position=11 of 40

  The book decides *labels* only. Game phases are never derived from it: the
  opening ends at the first position that no longer looks like an opening
  (material left, back rank, pawn structure), so swapping books - or having no
  book at all - cannot move a move from one phase paragraph to another.

CLOUD EVALUATIONS  (Review settings -> Cloud evaluations)
  lichess.org keeps a public store of Stockfish analysis. Asking for it costs
  about a fifth of a second per position and usually returns depth 25-75, while
  a local depth-18 MultiPV search costs 1-13 seconds. The pre-pass therefore
  asks for every position first and only searches locally what the cloud does
  not cover. Measured here on two games: 95% hits for a mainline Ruy Lopez, 40%
  for an offbeat line, 72% overall.
    off      no network traffic at all
    uniform  use the cloud only when it covers *every* position of the game;
             otherwise ignore it and search the whole game locally. A game
             judged from two sources has two baselines, and a centipawn loss
             across them is not a comparison.
    fill     use the cloud wherever it is good enough and search the rest
             locally. Faster, but two moves can then be judged at different
             depths - use with care.
  A cloud entry is used only when its depth is at least "Cloud: minimum depth"
  and it carries at least "Cloud: minimum PV lines" lines; a single PV line
  cannot drive the brilliant/great gap rule, so those positions are searched
  locally. No API key is needed. Nothing is sent except the position.

  The progress window opens before the book probe, and the cloud stage reports
  its own count and how many entries were usable ("Cloud evaluations (9
  usable) 12/28"), then hands the same window to the engine pass.

DATABASE LINE  (Review settings -> Database line in the report)
  Off by default. When on, one search of the open database for the final
  position adds a line to the coach's facts: how many games reached it and what
  White scored. Warning: scid has no save/restore for the game filter, so this
  replaces the current filter, and it is skipped on databases over 100,000
  games.

MODEL LIST
  "Load" next to the Model field asks the endpoint what it has
  (/v1/models, then Ollama's /api/tags) and fills the list, so the model is a
  pick instead of a guess. Model prose is normalised before it is written:
  markdown emphasis is stripped and SAN is repaired (nf3 -> Nf3, A6 -> a6), so
  a sloppy model cannot put a lowercase piece move into the PGN.

TROUBLESHOOTING
  A plugin that fails to load is reported in a dialog and skipped.
  This plugin also appends to  plugins/cr_load.log  on every start, e.g.

      2026-10-23 17:12:28 plugin load start; scidUserDir=C:/Users/.../scidCommunity
      2026-10-23 17:12:28 menu: cascade added under .menu.tools
      2026-10-23 17:12:28 plugin load done; enginecfg=yes

  * no cr_load.log at all  -> scid never loaded the plugins: check that this
    folder is  %APPDATA%\scidCommunity\plugins  and restart scid.
  * "menu: flat items added"  -> the cascade could not be built; the three
    entries are at the bottom of the Tools menu instead.
  * "settings load failed"    -> cr_settings.dat is unreadable; delete it.

NOTES
  * Estimated Elo is a fit to accuracy + ACPL, not a measurement. The
    performance rating uses "opponent RD" from settings: 100 (established
    rating) anchors it to the opponent; leaving it at 350 reduces it to the
    plain strength estimate.
