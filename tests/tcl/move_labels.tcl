# Copyright (C) 2026 David Crandall
# SPDX-License-Identifier: GPL-2.0-or-later
#
# move_labels.tcl -- the label ladder, in tclsh.
#
#   tclsh tests/tcl/move_labels.tcl
#
# The ladder is a threshold table, so the tests are a table too: one row per
# boundary that decides a label, plus the mate transitions that no centipawn
# table can express. A property check pins the one thing a table cannot: a
# bigger loss never earns a better label.

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

puts "labels"

# The best move is best whatever the score did: the label says the move was the
# engine's choice, not that the position stayed good.
checkEq "the engine's own move is best" [::movelabels::label -900 -900 1] best

# Table: {before after expected drop expected}, both from the mover's point of
# view. The drop is pinned with the label so a threshold cannot drift silently:
# each pair sits just inside or just outside a boundary of the ladder.
set table {
    {20   18    excellent  0.18}
    {20   0     excellent  1.84}
    {20   -10   good       2.76}
    {20   -30   good       4.60}
    {20   -50   inaccuracy 6.43}
    {0    -49   good       4.50}
    {0    -99   inaccuracy 9.01}
    {0    -110  inaccuracy 9.99}
    {0    -111  mistake   10.08}
    {0    -230  mistake   19.99}
    {0    -240  blunder   20.76}
    {900  880   excellent  0.26}
    {900  850   good       0.68}
    {-900 -950   good       0.57}
}
foreach row $table {
    lassign $row b a want wantDrop
    checkEq "label $b -> $a" [::movelabels::label $b $a] $want
    set drop [::movelabels::winDrop $b $a]
    check "drop $b -> $a is $wantDrop" \
        [expr {abs($drop - $wantDrop) < 0.02}] "got [format %.2f $drop]"
}

# The two labels that also test the centipawn loss: a small win-percentage drop
# with a big loss is not "excellent". 900 -> 850 gives up half a pawn but the
# position was already won, so the curve barely moves - the loss guard decides.
check "a won position keeps a 50cp loss out of excellent" \
    [expr {[::movelabels::label 900 850] eq "good"}]
check "the same drop with a 20cp loss is excellent" \
    [expr {[::movelabels::label 900 880] eq "excellent"}]

# The boundaries themselves, in both directions.
check "a 1.93 point drop is still excellent" \
    [expr {[::movelabels::winDrop 0 -21] < 2 && [::movelabels::label 0 -21] eq "excellent"}]
check "a 2.02 point drop is not" \
    [expr {[::movelabels::winDrop 0 -22] >= 2 && [::movelabels::label 0 -22] eq "good"}]
check "a 4.95 point drop is still good" \
    [expr {[::movelabels::label 0 -54] eq "good"}]
check "a 5.05 point drop is an inaccuracy" \
    [expr {[::movelabels::label 0 -55] eq "inaccuracy"}]

# A mate is worth 100%, so losing one is the biggest drop there is; keeping the
# same mate is no loss at all.
set m3 [::movelabels::mateToCp 3]
set m2 [::movelabels::mateToCp 2]
set mNeg [::movelabels::mateToCp -3]
checkEq "delivering a mate stays excellent" [::movelabels::label $m3 $m2] excellent
checkEq "walking into a mate is a blunder" [::movelabels::label 0 $mNeg] blunder
checkEq "losing a won mate is a blunder" [::movelabels::label $m3 0] blunder
check "a mate score is recognised as a mate" [::movelabels::isMate $m3]
check "a tablebase centipawn score is not a mate" \
    [expr {![::movelabels::isMate 9165]}]

# UCI scores are from the side to move; the ladder wants the mover's view.
checkEq "black's move takes the negated score" \
    [::movelabels::forMover 120 {} b b] 120
checkEq "white's score is negated for a black mover" \
    [::movelabels::forMover 120 {} w b] -120
checkEq "mate scores are negated too" \
    [::movelabels::forMover {} 3 w b] [expr {-1 * [::movelabels::mateToCp 3]}]

# Monotonicity: for one starting score, a bigger drop never earns a better
# label. This is the property the threshold table exists to keep.
set order {best excellent good inaccuracy mistake blunder}
set prev -1
set monotone 1
foreach after {0 -20 -49 -50 -80 -99 -100 -200 -300 -500 -900} {
    set l [::movelabels::label 50 $after]
    set idx [lsearch -exact $order $l]
    if {$idx < $prev} { set monotone 0 }
    set prev $idx
}
check "a bigger loss never earns a better label" $monotone

# A whole game: White's evaluations in, one label per move out. Black's plies
# are judged from Black's side, so the same centipawn sequence reads differently
# for the two players.
set cps {0 0 0 0 0 -300 -300}
set labels [::movelabels::game $cps]
checkEq "one label per move" [llength $labels] 6
checkEq "white's quiet move is excellent" [lindex $labels 0] excellent
checkEq "black's quiet reply is excellent" [lindex $labels 1] excellent
checkEq "white blunders the eval" [lindex $labels 4] blunder
checkEq "black's reply is not blamed for it" [lindex $labels 5] excellent

# The engine's chosen plies are labelled best.
set chosen [::movelabels::game $cps {1 4}]
checkEq "a chosen ply is best" [lindex $chosen 1] best
checkEq "and the other plies are not" [lindex $chosen 0] excellent

puts "\n$checks checks, $fails failures"
exit [expr {$fails ? 1 : 0}]
