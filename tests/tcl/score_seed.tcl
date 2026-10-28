# Copyright (C) 2026 David Crandall
# SPDX-License-Identifier: GPL-2.0-or-later
#
# score_seed.tcl -- reading stored evaluations back into the score graph.
#
#   tclsh tests/tcl/score_seed.tcl

set fails 0
set checks 0
proc check {label cond {detail ""}} {
    incr ::checks
    if {$cond} {
        puts "  ok   $label"
    } else {
        incr ::fails
        if {$detail eq ""} { puts "  FAIL $label" } else { puts "  FAIL $label -- $detail" }
    }
}
proc checkEq {label got want} {
    check $label [expr {$got eq $want}] "got '$got' want '$want'"
}

set root [file normalize [file join [file dirname [info script]] .. ..]]
source [file join $root tcl tools score_seed.tcl]

puts "seed"

# The plain forms every exporter writes.
checkEq "a score" [::seed::score {[%eval 0.34]}] 34
checkEq "a negative score" [::seed::score {[%eval -1.20]}] -120
checkEq "zero" [::seed::score {[%eval 0.00]}] 0
checkEq "a mate" [::seed::score {[%eval #3]}] 99700
checkEq "a mate against" [::seed::score {[%eval #-3]}] -99700
checkEq "a mate already delivered" [::seed::score {[%eval #0]}] 100000

# Depth suffixes: Lichess writes score,depth and some exporters write score/depth.
checkEq "a score with a depth" [::seed::score {[%eval 0.34,18]}] 34
checkEq "a decimal comma with a depth" [::seed::score {[%eval -6,64/23]}] -664

# Surrounding text and other comments are ignored.
checkEq "embedded in a comment" [::seed::score {A good move. [%eval 1.05] Indeed.}] 105
checkEq "no evaluation" [::seed::score {A good move.}] {}
checkEq "an empty comment" [::seed::score {}] {}
checkEq "a malformed token" [::seed::score {[%eval abc]}] {}
checkEq "a token with trailing junk is not a score" [::seed::score {[%eval 0.34junk]}] {}
checkEq "a leading plus is still a score" [::seed::score {[%eval +0.20]}] 20

# The graph's range is a dozen pawns; a tablebase score must not flatten it.
checkEq "clamped high" [::seed::score {[%eval 25.00]}] 1200
checkEq "clamped low" [::seed::score {[%eval -25.00]}] -1200

# The graph's label for a seeded point.
checkEq "a positive score label" [::seed::label 34] {+0.34}
checkEq "a negative score label" [::seed::label -120] {-1.20}
checkEq "a mate label" [::seed::label 99700] {#3}
checkEq "a mate against" [::seed::label -99700] {#-3}
checkEq "a mate already delivered" [::seed::label 100000] {#0}

# The chart can show scores from the side to move; the stored value is White's.
checkEq "white's chart keeps the stored sign" [::seed::forSide -35 black white] -35
checkEq "an engine-side chart flips a black-to-move point" [::seed::forSide -35 black engine] 35
checkEq "and leaves a white-to-move one alone" [::seed::forSide 35 white engine] 35

# A game's comments, one per position from the start.
set comments [list {opening} {[%eval 0.20]} {} {[%eval -0.35]} {}]
set points [::seed::points $comments]
checkEq "the first comment is the position before move 1" [dict exists $points 0] 0
checkEq "a score lands on its ply" [dict get $points 1] 20
checkEq "a gap stays a gap" [dict exists $points 2] 0
checkEq "and the next score is still read" [dict get $points 3] -35
checkEq "two of five comments carry one" [dict size $points] 2
checkEq "an evaluation before the first move is not a ply" \
    [dict exists [::seed::points [list {[%eval 0.20]} {}]] 0] 0

# Half the plies is the point at which the graph stops needing an engine pass.
check "a half-covered game counts as covered" [::seed::covers {1 10 2 20} 4]
check "a stray comment does not" [expr {![::seed::covers {1 10} 8]}]
check "an empty game is not covered" [expr {![::seed::covers {} 0]}]

puts "\n$checks checks, $fails failures"
exit [expr {$fails ? 1 : 0}]
