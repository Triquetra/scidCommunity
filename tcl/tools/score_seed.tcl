# Copyright (C) 2026 David Crandall
# SPDX-License-Identifier: GPL-2.0-or-later
#
# score_seed.tcl -- turn the [%eval] comments already in a game into score-graph
# points, so the graph can show what is known before any engine runs.
#
# A game that came from Lichess, from a previous review, or from Ctrl+Shift+A
# already carries its evaluations. Re-searching those positions is wasted time
# and, worse, it replaces a stored score with a shallower guess. The graph reads
# them first and the engine only fills the gaps.
#
# Pure Tcl: the comment text in, centipawns out. The caller walks the game.

namespace eval ::seed {
    # The chart draws mates at this magnitude, the same encoding the engine pass
    # uses, so a stored mate and a searched mate look identical.
    variable MATE_CP 100000
    # Stored evaluations beyond this are clamped: the graph's vertical range is
    # a dozen pawns, and a +25.00 from a tablebase probe would flatten it.
    variable MAX_CP 1200
}

# Centipawns from a move comment, or "" when it carries no evaluation.
# Understands `[%eval 0.34]`, `[%eval #3]`, `[%eval #-3]`, `[%eval 0.34,18]`
# (score, depth - the depth is ignored here; provenance is the caller's) and
# the `[%eval -6,64/23]` form some exporters write.
proc ::seed::score {comment} {
    variable MATE_CP
    variable MAX_CP
    if {![regexp {\[%eval\s+([^\]\s]+)} $comment -> token]} { return "" }
    # A mate is written #N or #-N; anything else is a score.
    if {[regexp {^#(-?)(\d+)} $token -> sign n]} {
        set dist [expr {$n eq "" ? 0 : $n}]
        set cp [expr {$MATE_CP - 100 * $dist}]
        return [expr {$sign eq "-" ? -$cp : $cp}]
    }
    # Strip the depth suffix and normalise a decimal comma before scanning.
    set value [lindex [split [string map {, .} $token] "/"] 0]
    if {[scan $value %f pawns] != 1} { return "" }
    set cp [expr {round($pawns * 100)}]
    if {$cp > $MAX_CP} { return $MAX_CP }
    if {$cp < -$MAX_CP} { return -$MAX_CP }
    return $cp
}

# The score as the graph's label shows it: pawns with a sign, or #N for a mate.
proc ::seed::label {cp} {
    variable MATE_CP
    # A mate is anything past this: the encodings only ever reach it that way.
    if {abs($cp) >= $MATE_CP - 100 * 60} {
        set dist [expr {abs($cp) >= $MATE_CP ? 0 : int(($MATE_CP - abs($cp)) / 100)}]
        return [expr {$cp > 0 ? "#$dist" : "#-$dist"}]
    }
    return [format {%+.2f} [expr {$cp / 100.0}]]
}

# A dict of ply -> centipawns from a list of comments, where the list is indexed
# from ply 1 (element 0 is the comment of the position before the first move and
# is ignored). Plies without an evaluation are simply absent, which is what the
# caller tests to decide what to search.
proc ::seed::points {comments} {
    set out [dict create]
    set ply 0
    foreach comment $comments {
        incr ply
        if {$ply < 1} continue
        set cp [score $comment]
        if {$cp eq ""} continue
        dict set out $ply $cp
    }
    return $out
}

# Does this game already know its scores? True when at least half the plies
# carry one: a single stray comment should not stop the engine pass.
proc ::seed::covers {points plies} {
    if {$plies < 1} { return 0 }
    return [expr {[dict size $points] * 2 >= $plies}]
}
