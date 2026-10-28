# Copyright (C) 2026 David Crandall
# SPDX-License-Identifier: GPL-2.0-or-later
#
# game_review.tcl -- the review pass's settings and decisions.
#
# The engine work lives with the engine layer; this file owns the choices that
# decide what the pass does and what it writes back, so they can be tested
# without an engine and without Tk:
#
#   * how deep and how many lines the pass searches (mpv, depth);
#   * where the pass starts, given the opening book (bookEnd - 1, so the move
#     that leaves the book has the reference position it needs);
#   * which of the engine's lines become variations in the game, and how far
#     behind the best line a variation may be before it is noise (var_lines,
#     var_cp).
#
# Nothing here searches and nothing here writes: the caller supplies the
# results and does the sc_* work.

namespace eval ::review {
    variable DEFAULTS {
        mpv 3
        depth 18
        var_lines 0
        var_cp 0
        threads 0
        hash_mb 128
        skip_book 1
    }
    variable S [dict create]
    variable MAX_MPV 5
    variable MIN_DEPTH 6
    variable MAX_DEPTH 60
}

proc ::review::defaults {} {
    variable DEFAULTS
    return $DEFAULTS
}

# Settings start at the defaults and are then whatever the caller saved.
proc ::review::reset {} {
    variable S
    variable DEFAULTS
    set S $DEFAULTS
    return $S
}

proc ::review::all {} {
    variable S
    if {![dict size $S]} { reset }
    return $S
}

proc ::review::get {key} {
    variable S
    if {![dict size $S]} { reset }
    if {![dict exists $S $key]} { error "unknown review setting: $key" }
    return [dict get $S $key]
}

# Set one setting, refusing values the pass cannot honour. Returns "" on
# success or the reason it was refused; the old value is kept either way.
proc ::review::setValue {key value} {
    variable S
    variable MAX_MPV
    variable MIN_DEPTH
    variable MAX_DEPTH
    if {![dict size $S]} { reset }
    if {![dict exists $S $key]} { return "unknown setting: $key" }
    if {![string is integer -strict $value]} { return "$key must be a whole number" }
    set previous [dict get $S $key]
    set value [expr {$value}]
    switch -- $key {
        mpv {
            if {$value < 1 || $value > $MAX_MPV} { return "mpv must be 1..$MAX_MPV" }
        }
        depth {
            if {$value < $MIN_DEPTH || $value > $MAX_DEPTH} {
                return "depth must be $MIN_DEPTH..$MAX_DEPTH"
            }
        }
        var_lines {
            if {$value < 0} { return "var_lines cannot be negative" }
        }
        var_cp {
            if {$value < 0} { return "var_cp cannot be negative" }
        }
        threads {
            if {$value < 0} { return "threads cannot be negative" }
        }
        hash_mb {
            if {$value < 16} { return "hash_mb must be at least 16" }
        }
        skip_book {
            if {$value < 0 || $value > 1} { return "skip_book is 0 or 1" }
        }
        default { return "unknown setting: $key" }
    }
    dict set S $key $value
    # var_lines is capped by mpv, and lowering mpv must lower the cap with it.
    if {[dict get $S var_lines] > [dict get $S mpv]} {
        if {$key eq "mpv"} {
            dict set S var_lines [dict get $S mpv]
        } else {
            dict set S $key $previous
            return "var_lines cannot exceed mpv ([dict get $S mpv])"
        }
    }
    return ""
}

# Cross-field problems, for a dialog that wants to show them all at once.
proc ::review::problems {} {
    set s [all]
    set out {}
    if {[dict get $s var_lines] > [dict get $s mpv]} {
        lappend out "var_lines ([dict get $s var_lines]) exceeds mpv ([dict get $s mpv])"
    }
    if {[dict get $s var_lines] > 0 && [dict get $s mpv] < 2} {
        lappend out "var_lines needs mpv of at least 2"
    }
    return $out
}

# Position index the engine pass starts at.
#
# `bookEnd` is the first position that is no longer in the book (0 when the
# game never leaves it, or when book skipping is off). The pass starts one
# position EARLIER: the label for the move that leaves the book is judged from
# the evaluations and the alternative lines of the position before it, so
# starting at bookEnd would leave that move unjudgeable - the exact case an
# early novelty needs.
proc ::review::startPly {bookEnd} {
    set s [all]
    if {![dict get $s skip_book]} { return 0 }
    if {$bookEnd <= 0} { return 0 }
    return [expr {$bookEnd - 1}]
}

# The plies to search: every move from `startPly` to the end of the line.
# `plies` is the number of moves in the main line.
proc ::review::plan {plies bookEnd} {
    set out {}
    set start [startPly $bookEnd]
    for {set i [expr {$start + 1}]} {$i <= $plies} {incr i} { lappend out $i }
    return $out
}

# Which of the engine's lines become variations.
#
# `lines` is a list of {cp pv}, best first, in centipawns from the mover's point
# of view - the same figure the label ladder uses. The first line is the game's
# own move when it was best, so only lines 2..var_lines are candidates.
#
# var_cp is a noise filter: a line that is further behind the best line than
# var_cp centipawns is not worth inserting. The comparison is strict, so a
# threshold of 50 excludes a line exactly 50cp worse - "3.0 or more" in the
# worked example. var_cp 0 means no filter at all.
proc ::review::selectLines {lines} {
    set s [all]
    set want [dict get $s var_lines]
    set limit [dict get $s var_cp]
    if {$want < 1 || [llength $lines] < 2} { return {} }
    set best [lindex [lindex $lines 0] 0]
    set out {}
    foreach line [lrange $lines 1 end] {
        if {[llength $out] >= $want} { break }
        lassign $line cp pv
        if {![llength $pv]} { continue }
        # An alternative that is ahead of the "best" line means the caller
        # mis-ordered the lines; it is not a reason to insert a variation.
        if {$cp > $best} { continue }
        if {$limit > 0 && ($best - $cp) >= $limit} { continue }
        lappend out $pv
    }
    return $out
}
