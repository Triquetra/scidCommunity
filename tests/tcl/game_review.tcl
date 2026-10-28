# Copyright (C) 2026 David Crandall
# SPDX-License-Identifier: GPL-2.0-or-later
#
# game_review.tcl -- the review pass's settings and its two decisions.
#
#   tclsh tests/tcl/game_review.tcl

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
source [file join $root tcl tools accuracy.tcl]
source [file join $root tcl tools move_labels.tcl]
source [file join $root tcl tools score_seed.tcl]
source [file join $root tcl tools game_review.tcl]

puts "settings"

::review::reset
checkEq "mpv defaults to 3" [::review::get mpv] 3
checkEq "depth defaults to 18" [::review::get depth] 18
checkEq "variations are off by default" [::review::get var_lines] 0
checkEq "no threshold by default" [::review::get var_cp] 0

checkEq "mpv can be raised" [::review::setValue mpv 4] ""
checkEq "and is remembered" [::review::get mpv] 4
checkEq "mpv above the cap is refused" [::review::setValue mpv 9] {mpv must be 1..5}
checkEq "and keeps the old value" [::review::get mpv] 4
checkEq "depth can be raised" [::review::setValue depth 24] ""
checkEq "a shallow depth is refused" [::review::setValue depth 4] {depth must be 6..60}
checkEq "a non-number is refused" [::review::setValue depth deep] {depth must be a whole number}
checkEq "an unknown key is refused" [::review::setValue colour red] {unknown setting: colour}

# var_lines cannot exceed mpv, and lowering mpv lowers it.
checkEq "var_lines above mpv is refused" [::review::setValue var_lines 5] {var_lines cannot exceed mpv (4)}
::review::setValue mpv 5
checkEq "var_lines up to mpv is accepted" [::review::setValue var_lines 5] ""
checkEq "it is remembered" [::review::get var_lines] 5
::review::setValue mpv 2
checkEq "lowering mpv lowers var_lines with it" [::review::get var_lines] 2
checkEq "no problems reported" [::review::problems] {}

puts "where the pass starts"

::review::reset
checkEq "no book, start at the first move" [::review::startPly 0] 0
checkEq "book ends at position 7: start one earlier" [::review::startPly 7] 6
checkEq "the plan runs from there to the end" [::review::plan 10 7] {7 8 9 10}
checkEq "the whole game when there is no book" [::review::plan 3 0] {1 2 3}
::review::setValue skip_book 0
checkEq "with book skipping off the pass starts at move 1" [::review::startPly 7] 0
checkEq "and covers the whole game" [::review::plan 3 7] {1 2 3}

puts "which lines become variations"

::review::reset
set lines {{20 pvA} {10 pvB} {-30 pvC}}
checkEq "no variations by default" [::review::selectLines $lines] {}
::review::setValue var_lines 2
checkEq "two alternates, best first" [::review::selectLines $lines] {pvB pvC}
checkEq "one alternate" [::review::selectLines [list {20 pvA} {10 pvB}]] {pvB}
checkEq "a single line has no alternate" [::review::selectLines [list {20 pvA}]] {}

# The worked example: best +2.50 for White is -250 for the Black mover, and an
# alternative that scores +3.00 is 50cp worse, so a 50cp threshold excludes it.
set example [list {-250 pvBest} {-300 pvWorse} {-280 pvCloser}]
checkEq "no threshold keeps both" [::review::selectLines $example] {pvWorse pvCloser}
::review::setValue var_cp 50
checkEq "a 50cp threshold drops the line exactly 50 worse" \
    [::review::selectLines $example] {pvCloser}
::review::setValue var_cp 100
checkEq "a wider threshold keeps them" [::review::selectLines $example] {pvWorse pvCloser}

# Lines that are not in order, or have no moves, are not variations.
checkEq "a line ahead of the best is ignored" \
    [::review::selectLines [list {10 pvA} {40 pvAhead}]] {}
checkEq "a line with no moves is ignored" \
    [::review::selectLines [list {10 pvA} {-20 {}}]] {}

# var_lines is the count that is inserted, not the count that is examined.
::review::setValue mpv 5
::review::setValue var_lines 1
::review::setValue var_cp 0
checkEq "only the first eligible alternate" \
    [::review::selectLines {{20 a} {10 b} {5 c}}] {b}

puts "when the move comment may write"

::review::reset
checkEq "by default it waits for the review depth" [::review::moveCommentPlan 12] 18
checkEq "at the review depth it writes" [::review::moveCommentPlan 18] now
checkEq "deeper than the review depth writes too" [::review::moveCommentPlan 22] now
checkEq "with no depth reported it waits" [::review::moveCommentPlan ""] 18
::review::setValue move_comment_wait 0
checkEq "immediate mode writes whatever the engine has" [::review::moveCommentPlan 4] now
checkEq "and writes even with nothing to report" [::review::moveCommentPlan ""] now

puts "the comment a move carries"

::review::reset
check "the label and the evaluation" \
    [string match {*\[%eval -1.20\]*} [::review::commentText blunder -120]]
check "a label without an evaluation" \
    [expr {[string first "%eval" [::review::commentText good ""]] < 0}]
checkEq "an existing comment is kept" \
    [::review::mergeComment {A fine move.} {[Blunder]}] {A fine move. [Blunder]}
checkEq "and is not repeated" \
    [::review::mergeComment {A fine move. [Blunder]} {[Blunder]}] {A fine move. [Blunder]}
checkEq "an empty comment is just the new text" \
    [::review::mergeComment {} {[Good]}] {[Good]}

puts "writing one move"

# The sc_* layer is stubbed: the point of these checks is which calls are made,
# not what scid does with them.
set ::calls {}
proc sc_pos {args} {
    switch -- [lindex $args 0] {
        location { return $::fakeLoc }
        getComment { return $::fakeComment }
        setComment { lappend ::calls [list setComment [lindex $args 1]] ; set ::fakeComment [lindex $args 1] ; return "" }
    }
    return ""
}
proc sc_move {args} {
    # A game of ::fakeLen moves: asking for a ply beyond it leaves the game
    # where it was, which is what the real command does.
    if {[lindex $args 0] eq "ply"} {
        if {[lindex $args 1] <= $::fakeLen} { set ::fakeLoc [lindex $args 1] }
    }
    if {[lindex $args 0] eq "back"} { incr ::fakeLoc -1 }
    lappend ::calls [list move [lindex $args 0] [lindex $args 1]]
    return ""
}
proc sc_var {args} {
    lappend ::calls [list var [lindex $args 0]]
    if {[lindex $args 0] eq "count"} { return 0 }
    return ""
}
namespace eval ::uci { proc sc_move_add {moves} { lappend ::calls [list add $moves] ; return 0 } }

::review::reset
::review::setValue var_lines 1
set ::fakeLen 10
set ::fakeLoc 5
set ::fakeComment "Existing note."
set ::calls {}
set err [::review::writeMove 4 blunder -120 {{-120 pvBest} {-200 pvAlt}}]
checkEq "it succeeds" $err {}
check "the comment is written at the move" \
    [expr {[lsearch -exact $::calls {setComment {Existing note. [blunder] [%eval -1.20]}}] >= 0}]
check "a variation is created" [expr {[lsearch -exact $::calls {var create}] >= 0}]
check "with the alternate line" [expr {[lsearch -exact $::calls {add pvAlt}] >= 0}]
check "and the game is left where it was" [expr {$::fakeLoc == 5}]

# No variations when the setting is off, and none when the move is not there.
set ::calls {}
::review::setValue var_lines 0
::review::writeMove 4 good 20 {{20 pvBest} {10 pvAlt}}
check "no variation with var_lines 0" [expr {[lsearch -exact $::calls {var create}] < 0}]

set ::fakeLen 3
set ::fakeLoc 2
checkEq "a ply that is not in the game is refused" \
    [::review::writeMove 4 good 20 {}] {ply 4 is not in this game}

puts "\n$checks checks, $fails failures"
exit [expr {$fails ? 1 : 0}]
