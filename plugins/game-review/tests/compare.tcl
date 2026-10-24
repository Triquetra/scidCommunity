# compare.tcl -- diff the Tcl port against Patzer's TypeScript output.
# Reads /tmp/oracle.txt (produced by oracle.mjs) and recomputes every case.
source [file join [file dirname [info script]] cr_board.tcl]
source [file join [file dirname [info script]] cr_classify.tcl]

set fp [open /tmp/oracle.txt r]
set data [read $fp]
close $fp

set total 0
set bad 0
set report {}

proc numEq {a b {tol 1e-6}} {
    if {[string is double -strict $a] && [string is double -strict $b]} {
        return [expr {abs($a - $b) <= $tol}]
    }
    return [expr {$a eq $b}]
}

foreach line [split [string trim $data] \n] {
    if {$line eq ""} continue
    incr total
    set f [split $line |]
    set tag [lindex $f 0]
    switch -- $tag {
        SEE {
            lassign $f _ fen sq want
            set got [::crboard::see [::crboard::fromFen $fen] [::crboard::sqIndex $sq]]
            if {!($got == $want)} { incr bad ; lappend report "SEE $fen $sq want=$want got=$got" }
        }
        HANG {
            lassign $f _ fb fa side want
            set got [::crboard::hangingMaterial $fb $fa $side]
            if {!($got == $want)} { incr bad ; lappend report "HANG want=$want got=$got | $fb | $fa | $side" }
        }
        WPDROP {
            lassign $f _ wp cp best want
            set got [::crclass::classifyByWpDrop $wp $cp [expr {$best eq "1"}]]
            if {$got ne $want} { incr bad ; lappend report "WPDROP $wp $cp $best want=$want got=$got" }
        }
        REFINE {
            lassign $f _ base isBest cpLoss fb fa side evb eva ply legal cands inBook want
            set got [::crclass::refineClassification \
                -base $base -isBest [expr {$isBest eq "1"}] -cpLoss $cpLoss \
                -fenBefore $fb -fenAfter $fa -sideToMove $side \
                -playerEvalBeforeCp $evb -playerEvalAfterCp $eva -ply $ply \
                -legalMoveCount $legal -candidatePlayerCps [split $cands ,] \
                -inBook [expr {$inBook eq "null" ? "" : $inBook}]]
            if {$got ne $want} {
                incr bad
                lappend report "REFINE base=$base best=$isBest cpl=$cpLoss ply=$ply legal=$legal ev=$evb/$eva cands=$cands book=$inBook want=$want got=$got | $fb | $fa | $side"
            }
        }
        WINPCT {
            lassign $f _ cp want
            set got [format %.6f [::crclass::cpToWinPct $cp]]
            if {![numEq $got $want]} { incr bad ; lappend report "WINPCT $cp want=$want got=$got" }
        }
        MOVEACC {
            lassign $f _ wb wa want
            set got [format %.6f [::crclass::moveAccuracy $wb $wa]]
            if {![numEq $got $want]} { incr bad ; lappend report "MOVEACC $wb $wa want=$want got=$got" }
        }
        ELOACPL {
            lassign $f _ a want
            set got [::crclass::eloFromAcpl $a]
            if {!($got == $want)} { incr bad ; lappend report "ELOACPL $a want=$want got=$got" }
        }
        ESTELO {
            lassign $f _ acc acpl want
            set got [::crclass::estimateElo $acc $acpl]
            if {!($got == $want)} { incr bad ; lappend report "ESTELO $acc $acpl want=$want got=$got" }
        }
        PERF {
            lassign $f _ opp rd score want
            set got [::crclass::estimateGamePerformance -accuracy 77.3 -acpl 31.4 \
                -opponentRating [expr {$opp eq "null" ? "" : $opp}] -opponentRd $rd -score $score]
            if {!($got == $want)} { incr bad ; lappend report "PERF $opp $rd $score want=$want got=$got" }
        }
        CPLOSS {
            lassign $f _ b a want1 want2
            set g1 [::crclass::cpLossForPly $b $a]
            set g2 [::crclass::cpLossForAcpl $b $a]
            if {!($g1 == $want1 && $g2 == $want2)} {
                incr bad ; lappend report "CPLOSS $b->$a want=$want1/$want2 got=$g1/$g2"
            }
        }
        WINDROP {
            lassign $f _ b a want
            set got [format %.6f [::crclass::winDropForPly $b $a 60 40]]
            if {![numEq $got $want]} { incr bad ; lappend report "WINDROP $b->$a want=$want got=$got" }
        }
        NORM {
            lassign $f _ cp mate side want
            set got [::crclass::normalizeEval [expr {$cp eq "null" ? "" : $cp}] \
                [expr {$mate eq "null" ? "" : $mate}] $side]
            if {!($got == $want)} { incr bad ; lappend report "NORM $cp $mate $side want=$want got=$got" }
        }
        MATERIAL {
            lassign $f _ fen wantw wantb
            lassign [::crboard::material [::crboard::fromFen $fen]] gw gb
            if {!($gw == $wantw && $gb == $wantb)} { incr bad ; lappend report "MATERIAL want=$wantw/$wantb got=$gw/$gb" }
        }
        ACCURACY {
            lassign $f _ pts want
            set plist {}
            foreach pair [split $pts ";"] {
                lassign [split $pair ,] a w b
                lappend plist [list $a $w $b]
            }
            set got [format %.6f [::crclass::gameAccuracy $plist]]
            if {![numEq $got $want 1e-5]} { incr bad ; lappend report "ACCURACY want=$want got=$got" }
        }
        KEYMOM {
            lassign $f _ spec want
            set moves {}
            foreach m [split $spec ";"] {
                lassign [split $m ,] ply cls eb ea
                lappend moves [dict create ply $ply classification $cls \
                    eval_before_cp $eb eval_after_cp $ea san "x" fen_before "" fen_after "" \
                    centipawn_loss [expr {abs($eb - $ea)}] best_move_san "" best_pv ""]
            }
            set kms [::crclass::extractKeyMoments $moves 5]
            set got [join [lmap k $kms {dict get $k ply}] ,]
            if {$got ne $want} { incr bad ; lappend report "KEYMOM want=$want got=$got" }
        }
        default {
            lappend report "UNKNOWN TAG $tag"
            incr bad
        }
    }
}

puts "cases: $total   mismatches: $bad"
foreach r [lrange $report 0 20] { puts "  $r" }
if {[llength $report] > 21} { puts "  ... [expr {[llength $report]-21}] more" }
