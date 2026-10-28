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
checkEq "no variations by default" [::review::selectLines $lines pvA] {}
::review::setValue var_lines 2
checkEq "two alternates, best first" [::review::selectLines $lines pvA] {pvB pvC}
checkEq "one alternate" [::review::selectLines [list {20 pvA} {10 pvB}] pvA] {pvB}
checkEq "the played move's own line is not a variation" \
    [::review::selectLines [list {20 pvA}] pvA] {}
# A blunder: the best line is not the move played, so it is the variation the
# game is missing - not line 2 of the engine's list.
checkEq "the best line is a variation when the game played something else" \
    [::review::selectLines $lines Qxd8] {pvA pvB}
checkEq "the played move is dropped wherever it ranks" \
    [::review::selectLines {{20 pvA} {10 pvB} {5 pvC}} pvB] {pvA pvC}
# Nothing is dropped when the caller cannot say which move was played.
checkEq "an unknown played move keeps the best line" \
    [::review::selectLines [list {20 pvA} {10 pvB}]] {pvA pvB}

# The worked example: best +2.50 for White is -250 for the Black mover, and an
# alternative that scores +3.00 is 50cp worse, so a 50cp threshold excludes it.
set example [list {-250 pvBest} {-300 pvWorse} {-280 pvCloser}]
checkEq "no threshold keeps both" [::review::selectLines $example pvBest] {pvWorse pvCloser}
::review::setValue var_cp 50
checkEq "a 50cp threshold drops the line exactly 50 worse" \
    [::review::selectLines $example pvBest] {pvCloser}
::review::setValue var_cp 100
checkEq "a wider threshold keeps them" [::review::selectLines $example pvBest] {pvWorse pvCloser}

# Lines that are not in order, or have no moves, are not variations.
checkEq "a line ahead of the best is ignored" \
    [::review::selectLines [list {10 pvA} {40 pvAhead}] pvA] {}
checkEq "a line with no moves is ignored" \
    [::review::selectLines [list {10 pvA} {-20 {}}] pvA] {}

# var_lines is the count that is inserted, not the count that is examined.
::review::setValue mpv 5
::review::setValue var_lines 1
::review::setValue var_cp 0
checkEq "only the first eligible alternate" \
    [::review::selectLines {{20 a} {10 b} {5 c}} a] {b}

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

# A second review has to replace what the first one wrote: one verdict, and the
# [%eval] the graph reads first must be the new one.
checkEq "a previous verdict and score are removed" \
    [::review::stripReviewTokens {A fine move. [good] [%eval +0.20]}] {A fine move.}
checkEq "other tokens and the prose survive" \
    [::review::stripReviewTokens {[%clk 0:03:00] A fine move.}] {[%clk 0:03:00] A fine move.}
checkEq "a re-review leaves one verdict and one score" \
    [::review::mergeComment \
        [::review::stripReviewTokens {A fine move. [good] [%eval +0.20]}] \
        [::review::commentText blunder -120]] \
    {A fine move. [blunder] [%eval -1.20]}

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
    switch -- [lindex $args 0] {
        count { return 0 }
        list  { lappend ::listAt $::fakeLoc ; return $::fakeVars }
    }
    return ""
}
set ::fakeVars {}
set ::listAt {}
# UCI_mainLine is the setup followed by the moves, as the real command returns
# it, so element $ply is the move played at ply $ply.
proc sc_game {args} {
    if {[lindex $args 0] eq "UCI_mainLine"} { return $::fakeMainLine }
    return ""
}
namespace eval ::uci { proc sc_move_add {moves} { lappend ::calls [list add $moves] ; return 0 } }

::review::reset
::review::setValue var_lines 1
set ::fakeLen 10
set ::fakeLoc 5
set ::fakeComment "Existing note."
# The engine's best line is the move played at ply 4, so it is not a variation.
set ::fakeMainLine [list {position startpos moves} m1 m2 m3 pvBest m5]
set ::calls {}
set err [::review::writeMove 4 blunder -120 {{-120 pvBest} {-200 pvAlt}}]
checkEq "it succeeds" $err {}
check "the comment is written at the move" \
    [expr {[lsearch -exact $::calls {setComment {Existing note. [blunder] [%eval -1.20]}}] >= 0}]
check "a variation is created" [expr {[lsearch -exact $::calls {var create}] >= 0}]
check "with the alternate line" [expr {[lsearch -exact $::calls {add pvAlt}] >= 0}]
check "and not with the line the game already played" \
    [expr {[lsearch -exact $::calls {add pvBest}] < 0}]
check "and the game is left where it was" [expr {$::fakeLoc == 5}]

# A blunder: the best line is not the move played, so it is the variation.
set ::fakeMainLine [list {position startpos moves} m1 m2 m3 m5 m6]
set ::calls {}
::review::writeMove 4 blunder -120 {{-120 pvBest} {-200 pvAlt}}
check "the best line is inserted" [expr {[lsearch -exact $::calls {add pvBest}] >= 0}]
check "and the weaker line is not" [expr {[lsearch -exact $::calls {add pvAlt}] < 0}]

# No variations when the setting is off, and none when the move is not there.
set ::calls {}
::review::setValue var_lines 0
::review::writeMove 4 good 20 {{20 pvBest} {10 pvAlt}}
check "no variation with var_lines 0" [expr {[lsearch -exact $::calls {var create}] < 0}]

set ::fakeLen 3
set ::fakeLoc 2
checkEq "a ply that is not in the game is refused" \
    [::review::writeMove 4 good 20 {}] {ply 4 is not in this game}
check "and the game is left where it was, not moved to the start" \
    [expr {$::fakeLoc == 2}]

# var_lines > 1 inserts every distinct alternative, and a variation a previous
# review already wrote is not duplicated.
::review::reset
::review::setValue var_lines 2
set ::fakeLen 10
set ::fakeLoc 5
set ::fakeComment "Existing note."
set ::fakeMainLine [list {position startpos moves} m1 m2 m3 pvBest m5]
set ::fakeVars {}
set ::listAt {}
set ::calls {}
::review::writeMove 4 blunder -120 {{-120 pvBest} {-200 pvAlt} {-250 pvThird}}
check "both alternates are inserted" \
    [expr {[lsearch -exact $::calls {add pvAlt}] >= 0 \
        && [lsearch -exact $::calls {add pvThird}] >= 0}] $::calls
check "two variations are created" \
    [expr {[llength [lsearch -all $::calls {var create}]] == 2}] $::calls
checkEq "the variation list is read before the move, not after it" \
    [lindex $::listAt 0] 3
set ::fakeVars {pvAlt}
set ::calls {}
::review::writeMove 4 blunder -120 {{-120 pvBest} {-200 pvAlt} {-250 pvThird}}
check "an existing variation is not duplicated" \
    [expr {[lsearch -exact $::calls {add pvAlt}] < 0}] $::calls
check "a new one is still added" \
    [expr {[lsearch -exact $::calls {add pvThird}] >= 0}] $::calls

puts "\n$checks checks, $fails failures"
exit [expr {$fails ? 1 : 0}]
