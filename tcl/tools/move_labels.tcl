# Copyright (C) 2026 David Crandall
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Move labels: best, excellent, good, inaccuracy, mistake, blunder.
#
# The game's moves carry a score; what a reader wants is what the score meant.
# This turns the two evaluations around a move into one label, using the win
# percentage curve the tree already computes with (::accuracy::winPercent) so a
# label and an accuracy number can never disagree about the same move.
#
# Pure functions, no Tk and no sc_* commands: testable from tclsh. Nothing here
# searches or calls an engine - the caller supplies the evaluations.
#
# Evaluations are centipawns from the mover's point of view, or a mate distance
# encoded with ::movelabels::mateToCp so the logistic curve handles it: a mate
# is a win of 100%, and losing one is the largest drop there is.
#
# The thresholds follow Patzer's classifier (classifier.ts, MIT, (c) Arsen
# Apostolov and contributors): a win-percentage drop is the primary test and the
# centipawn loss only guards the two best labels, because a drop of two points
# in a drawn position and in a won one mean very different things.
#   Permission is hereby granted, free of charge, to any person obtaining a copy
#   of this software and associated documentation files (the "Software"), to deal
#   in the Software without restriction, including without limitation the rights
#   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#   copies of the Software, and to permit persons to whom the Software is
#   furnished to do so, subject to the following conditions: The above copyright
#   notice and this permission notice shall be included in all copies or
#   substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS",
#   WITHOUT WARRANTY OF ANY KIND.

# The refinements that ask whether a move was a sacrifice or a free capture act
# on the position itself, so they need tcl/utils/chessboard.tcl. Load it when it
# is not there rather than duplicating move generation.
if {[llength [info commands ::chessboard::see]] == 0} {
    set _boards {}
    if {[info exists ::scidTclDir]} {
        lappend _boards [file join $::scidTclDir utils chessboard.tcl]
    }
    lappend _boards [file join [file dirname [info script]] .. utils chessboard.tcl]
    foreach _f $_boards {
        if {[file exists $_f]} {
            catch { source -encoding utf-8 $_f }
            break
        }
    }
    unset _boards _f
}

# The win-percentage curve lives in tools/accuracy.tcl, which the engine window
# sources when it first opens. A label can be asked for before that has ever
# happened, so load it here when it is missing instead of keeping a second copy
# of the formula that could drift from the accuracy number beside it.
if {[llength [info commands ::accuracy::winPercent]] == 0} {
    set _candidates {}
    if {[info exists ::scidTclDir]} {
        lappend _candidates [file join $::scidTclDir tools accuracy.tcl]
    }
    lappend _candidates [file join [file dirname [info script]] accuracy.tcl]
    foreach _f $_candidates {
        if {[file exists $_f]} {
            catch { source -encoding utf-8 $_f }
            break
        }
    }
    unset _candidates _f
}

namespace eval ::movelabels {
    # A mate is encoded far outside any evaluation a search can return, so
    # "big number means mate" cannot misread a tablebase score (Stockfish
    # reports those as centipawns in the thousands).
    variable MATE_CP_THRESHOLD 90000
    # Opening moves are book, not judgement: a label on ply 5 teaches nothing.
    variable BOOK_PLIES 12
    # A best move beats the second-best by this much: the only move that keeps
    # the game.
    variable GREAT_GAP 200
}

# Mate distance to centipawns. 0 is UCI's `mate 0`, the side to move already
# mated, so it encodes as the largest loss there is - not as a win. The distance
# is clamped to the furthest mate that still encodes past MATE_CP_THRESHOLD: a
# mate in 101 would otherwise land on 89900 and be scored on the centipawn curve
# as if it were an ordinary evaluation.
proc ::movelabels::mateToCp {mate} {
    variable MATE_CP_THRESHOLD
    set limit [expr {(100000 - $MATE_CP_THRESHOLD) / 100}]
    if {$mate > $limit} { set mate $limit }
    if {$mate < -$limit} { set mate [expr {-$limit}] }
    if {$mate > 0} { return [expr {100000 - $mate * 100}] }
    return [expr {-100000 - $mate * 100}]
}

proc ::movelabels::isMate {cp} {
    variable MATE_CP_THRESHOLD
    return [expr {abs($cp) >= $MATE_CP_THRESHOLD}]
}

# An engine score as `mover` sees it. UCI scores are from the side to move, so
# they are negated when the mover is the other side.
proc ::movelabels::forMover {cp mate stm mover} {
    if {$mate ne ""} {
        set val [mateToCp $mate]
    } elseif {$cp ne ""} {
        set val $cp
    } else {
        set val 0
    }
    if {$stm eq $mover} { return $val }
    return [expr {-$val}]
}

# Centipawns given up, mate-aware and capped: a mate thrown away is the largest
# loss the ladder has a name for, and an uncapped mate distance would dwarf it.
proc ::movelabels::cpLoss {before after} {
    if {[isMate $before] && [isMate $after]} {
        if {($before > 0) == ($after > 0)} { return 0 }
        # The signs say who mates, so negative to positive is the mover going
        # from being mated to mating. A legal move cannot produce that pair (a
        # mover already mated has no move to play), but cpLoss is "given up":
        # if the pair ever appears, an improvement must not read as the largest
        # loss there is.
        if {$before < 0 && $after > 0} { return 0 }
        return 1000
    }
    return [expr {min(1000, max(0, $before - $after))}]
}

# Percentage points of winning chances given up, mate-aware.
proc ::movelabels::winDrop {before after} {
    if {[isMate $before] && [isMate $after]} {
        if {($before > 0) == ($after > 0)} { return 0.0 }
        if {$before < 0 && $after > 0} { return 0.0 }
        return 100.0
    }
    set drop [expr {[::accuracy::winPercent $before] - [::accuracy::winPercent $after]}]
    return [expr {max(0.0, $drop)}]
}

# The label for one move. `before` and `after` are the evaluations of the
# position before the move and of the position after it, both from the mover's
# point of view; `isBest` marks the move the engine preferred.
proc ::movelabels::label {before after {isBest 0}} {
    if {$isBest} { return best }
    set drop [winDrop $before $after]
    set loss [cpLoss $before $after]
    # The two best labels need both tests: a drop of under two points in a
    # position where the move still throws away half a pawn is not "excellent".
    if {$drop < 2 && $loss < 50} { return excellent }
    if {$drop < 5 && $loss < 100} { return good }
    if {$drop < 10} { return inaccuracy }
    if {$drop < 20} { return mistake }
    return blunder
}

# The words a reader sees. The labels above are identifiers - what a PGN, a
# report or a test stores - and they must not change with the UI language; the
# display text comes from the translation table (MoveLabelBest and friends in
# tcl/lang/*.tcl), so a language file that has not been updated yet still shows
# the English word through tr()'s fallback.
proc ::movelabels::text {label} {
    if {[llength [info commands tr]] == 0} { return $label }
    return [tr "MoveLabel[string totitle $label]"]
}

# Labels for a whole game from a list of evaluations, one per position from the
# start (White's point of view, as ::accuracy::calculate takes them), so move i
# is the pair cps[i], cps[i+1]. `bestPlies` are 0-based ply indexes the engine
# chose; the caller knows them, this does not search.
proc ::movelabels::game {cps {bestPlies {}}} {
    set out {}
    set n [expr {[llength $cps] - 1}]
    for {set i 0} {$i < $n} {incr i} {
        set b [lindex $cps $i]
        set a [lindex $cps [expr {$i + 1}]]
        # White moves on even plies; for Black both evaluations flip sign.
        if {$i % 2 == 1} { set b [expr {-$b}] ; set a [expr {-$a}] }
        set isBest [expr {[lsearch -exact $bestPlies $i] >= 0}]
        lappend out [label $b $a $isBest]
    }
    return $out
}

# ---- refinements ----------------------------------------------------------
# The six labels above read one score pair. These read what the move did to the
# board and what the engine's other lines were, and are the vocabulary a reader
# actually learns from: forced, book, brilliant, great, miss.
#
# Follows Patzer's classifier.ts refineClassification (MIT).

proc ::movelabels::pieceValue {p} {
    switch -- [string tolower $p] {
        p { return 1 }
        n - b { return 3 }
        r { return 5 }
        q { return 9 }
    }
    return 0
}

# A capture that takes a piece standing there for free is the obvious move, not
# a great one: the opponent gave it away on the previous ply.
proc ::movelabels::isFreeCapture {fen uci} {
    # No early `return` inside the catch body: Tcl's catch swallows TCL_RETURN
    # and the value is lost, so the proc would answer 0 every time.
    set out 0
    if {[catch {
        set pos [::chessboard::fromFen $fen]
        set to [::chessboard::sqIndex [string range $uci 2 3]]
        set victim [lindex [dict get $pos board] $to]
        if {$victim ne ""} {
            set out [expr {[::chessboard::see $pos $to] >= [pieceValue $victim] - 1}]
        }
    }]} {}
    return $out
}

proc ::movelabels::balanceOf {fen side} {
    lassign [::chessboard::material [::chessboard::fromFen $fen]] w b
    if {[string index $side 0] eq "w"} { return [expr {$w - $b}] }
    return [expr {$b - $w}]
}

# Does the engine's line simply trade back, restoring the material balance
# within a pawn? A sacrifice that is recaptured at once is a trade, not a
# brilliant move, however wide the engine's gap.
proc ::movelabels::isTrivialRecapture {side fenBefore pv fenAfterPlayed} {
    set balanceBefore [balanceOf $fenBefore $side]
    if {![llength $pv]} { return 0 }
    set out 0
    if {[catch {
        set pos [::chessboard::fromFen $fenAfterPlayed]
        set first [lindex $pv 0]
        set to [::chessboard::sqIndex [string range $first 2 3]]
        if {[lindex [dict get $pos board] $to] ne ""} {
            set pos [::chessboard::makeMove $pos $first]
            foreach uci [lrange $pv 1 3] {
                set pos [::chessboard::makeMove $pos $uci]
            }
            set out [expr {($balanceBefore - [balanceOf [::chessboard::toFen $pos] $side]) <= 1}]
        }
    }]} {}
    return $out
}

# Refine a base label with what the move did and what the engine's alternatives
# were. `ctx` is a dict; every key is optional except the ones a rule needs.
#
#   is_best          1 when the engine chose this move
#   cp_before        evaluation before the move, mover's view (mate-encoded)
#   cp_after         evaluation after it, mover's view
#   cp_loss          ::movelabels::cpLoss of the two
#   win_drop         ::movelabels::winDrop of the two
#   ply              1-based ply of the move
#   legal_moves      number of legal moves in the position before it
#   in_book          explicit book flag; defaults to ply <= BOOK_PLIES
#   candidates       the engine's top evaluations from the mover's view, best
#                    first (MultiPV); the first two give the gap
#   played           the UCI move played
#   fen_before, fen_after, pv_after_played   the board, for the sacrifice test
#
# Returns forced, book, brilliant, great, miss, blunder, or the base label.
proc ::movelabels::refine {label ctx} {
    variable BOOK_PLIES
    variable GREAT_GAP
    array set A {
        is_best 0 cp_before 0 cp_after 0 cp_loss 0 win_drop 0.0 ply 1
        legal_moves 20 in_book "" candidates {} played ""
        fen_before "" fen_after "" pv_after_played {}
    }
    foreach {k v} $ctx {
        if {[info exists A($k)]} { set A($k) $v }
    }

    # One legal move is not a choice, however much it wins or loses.
    if {$A(legal_moves) == 1} { return forced }

    set inBook [expr {$A(in_book) ne "" ? $A(in_book) : ($A(ply) <= $BOOK_PLIES)}]
    set badMove [expr {[lsearch -exact {mistake blunder} $label] >= 0}]
    if {$inBook && !$badMove} { return book }

    # A sound sacrifice that keeps the game: the piece given up comes back, so
    # the move is brilliant rather than a blunder the engine happens to like.
    if {$A(is_best) && $A(ply) > $BOOK_PLIES && $A(cp_before) <= 500 && $A(cp_after) >= -50 && $A(cp_loss) <= 20} {
        set sacrificed 0
        if {$A(fen_before) ne "" && $A(fen_after) ne ""} {
            # the mover is the side that was to move in fen_before
            set stm [lindex [split $A(fen_before)] 1]
            catch { set sacrificed [::chessboard::hangingMaterial $A(fen_before) $A(fen_after) $stm] }
        }
        if {$sacrificed >= 2 && ![isTrivialRecapture \
                [lindex [split $A(fen_before)] 1] $A(fen_before) $A(pv_after_played) $A(fen_after)]} {
            return brilliant
        }
    }

    if {$A(ply) > $BOOK_PLIES} {
        # The only move that keeps the game: a wide gap between the best and
        # the second-best line. Not when the mover is already lost - then the
        # "only move" is a forced retreat - and not when it simply takes what
        # the opponent left hanging.
        if {$A(is_best) && [llength $A(candidates)] >= 2} {
            set top [lindex $A(candidates) 0]
            set second [lindex $A(candidates) 1]
            if {$top - $second >= $GREAT_GAP && $A(cp_after) >= -200 \
                && $A(cp_after) >= $A(cp_before) - 20 \
                && ($A(played) eq "" || $A(fen_before) eq "" \
                    || ![isFreeCapture $A(fen_before) $A(played)])} {
                return great
            }
        }
        # A rescue that turns a lost position into a playable one is the same
        # kind of find.
        if {$A(is_best) && $A(cp_before) <= -150 && $A(cp_after) >= -50} { return great }
    }

    # The two scales disagree near the ends of the curve, so a board loss that
    # big is a blunder even when the win-chance drop rounds under the line.
    if {!$A(is_best) && $A(ply) > $BOOK_PLIES && $A(cp_loss) >= 300 \
        && $A(win_drop) >= 12 && abs($A(cp_before)) < 500} {
        return blunder
    }

    # A miss is a move that was already an error and gave up a win, rather than
    # merely a worse move: it had a big advantage, or a mate, and no longer has.
    if {[lsearch -exact {inaccuracy mistake blunder} $label] >= 0} {
        if {$A(cp_before) >= 150 && $A(cp_after) < 50} { return miss }
        if {[isMate $A(cp_before)] && $A(cp_before) > 0 && ![isMate $A(cp_after)]} { return miss }
    }
    return $label
}
