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
}

# Mate distance to centipawns. 0 is a mate already delivered.
proc ::movelabels::mateToCp {mate} {
    if {$mate >= 0} { return [expr {100000 - $mate * 100}] }
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
        return 1000
    }
    return [expr {min(1000, max(0, $before - $after))}]
}

# Percentage points of winning chances given up, mate-aware.
proc ::movelabels::winDrop {before after} {
    if {[isMate $before] && [isMate $after]} {
        if {($before > 0) == ($after > 0)} { return 0.0 }
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
