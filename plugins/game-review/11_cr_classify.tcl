# cr_classify.tcl -- Patzer's classification/accuracy/Elo rules, ported to Tcl.
# Source of truth: patzer server/src/chess/classifier.ts (SCORING_VERSION 9),
# keyMoments.ts, accuracy.ts. Verified line-by-line against the TypeScript.
#
# Pure functions, no Tk, no scid commands: testable from tclsh.

namespace eval ::crclass {
    # classifier.ts:33 and :39 - bump when the port is re-synced upstream.
    variable SCORING_VERSION 9
    variable BOOK_PLIES 12
    # Mate scores live far outside the centipawn range on purpose: Stockfish
    # reports tablebase wins as centipawns in the thousands (9165, 7836), so a
    # "big number means mate" rule mislabels them. Mate is encoded as
    # +/-(100000 - 100*moves), which no evaluation can reach.
    variable MATE_CP_THRESHOLD 90000

    # classification.ts:CLASS_WEIGHT, used by the key-moment ranking.
    variable CLASS_WEIGHT
    array set CLASS_WEIGHT {
        brilliant 9 miss 8 great 7 blunder 6 mistake 4 inaccuracy 1.5
    }
}

proc ::crclass::cpToWinPct {cp} {
    set v [expr {2.0 / (1.0 + exp(-0.00368208 * $cp)) - 1.0}]
    return [expr {50.0 + 50.0 * $v}]
}

proc ::crclass::moveAccuracy {winBefore winAfter} {
    set delta [expr {max(0.0, $winBefore - $winAfter)}]
    set acc [expr {103.1668 * exp(-0.04354 * $delta) - 3.1669}]
    if {$acc > 100.0} { return 100.0 }
    if {$acc < 0.0} { return 0.0 }
    return $acc
}

proc ::crclass::classifyByWpDrop {winPctDrop cpLoss isBest} {
    if {$isBest} { return best }
    if {$winPctDrop < 2 && $cpLoss < 50} { return excellent }
    if {$winPctDrop < 5 && $cpLoss < 100} { return good }
    if {$winPctDrop < 10} { return inaccuracy }
    if {$winPctDrop < 20} { return mistake }
    return blunder
}

proc ::crclass::isMateCp {cp} {
    variable MATE_CP_THRESHOLD
    return [expr {abs($cp) >= $MATE_CP_THRESHOLD}]
}

proc ::crclass::mateToCp {mate} {
    # 0 means the mate has just been delivered (the mating move itself)
    if {$mate >= 0} { return [expr {100000 - $mate * 100}] }
    return [expr {-100000 - $mate * 100}]
}

proc ::crclass::normalizeEval {cp mate sideToMove} {
    if {$mate ne ""} {
        set val [mateToCp $mate]
    } elseif {$cp ne ""} {
        set val $cp
    } else {
        set val 0
    }
    if {$sideToMove eq "w"} { return $val }
    return [expr {-$val}]
}

proc ::crclass::cpLossForPly {before after} {
    set bm [isMateCp $before]
    set am [isMateCp $after]
    if {$bm && $am} {
        if {($before > 0) == ($after > 0)} { return 0 }
        return 1000
    }
    return [expr {min(1000, max(0, $before - $after))}]
}

proc ::crclass::cpLossForAcpl {before after} {
    return [expr {min(300, [cpLossForPly $before $after])}]
}

proc ::crclass::winDropForPly {before after winBefore winAfter} {
    set bm [isMateCp $before]
    set am [isMateCp $after]
    if {$bm && $am} {
        if {($before > 0) == ($after > 0)} { return 0 }
        return 100
    }
    return [expr {max(0.0, $winBefore - $winAfter)}]
}

# classifier.ts:eloFromAcpl - piecewise-linear ACPL -> strength fit (v6).
proc ::crclass::eloFromAcpl {acpl} {
    set a [expr {max(0.0, $acpl)}]
    if {$a <= 8} {
        set elo [expr {2900 - ($a / 8.0) * 200}]
    } elseif {$a <= 12} {
        set elo [expr {2700 - (($a - 8) / 4.0) * 200}]
    } elseif {$a <= 18} {
        set elo [expr {2500 - (($a - 12) / 6.0) * 300}]
    } elseif {$a <= 25} {
        set elo [expr {2200 - (($a - 18) / 7.0) * 300}]
    } elseif {$a <= 35} {
        set elo [expr {1900 - (($a - 25) / 10.0) * 300}]
    } elseif {$a <= 50} {
        set elo [expr {1600 - (($a - 35) / 15.0) * 200}]
    } elseif {$a <= 70} {
        set elo [expr {1400 - (($a - 50) / 20.0) * 200}]
    } elseif {$a <= 100} {
        set elo [expr {1200 - (($a - 70) / 30.0) * 300}]
    } elseif {$a <= 150} {
        set elo [expr {900 - (($a - 100) / 50.0) * 300}]
    } elseif {$a <= 250} {
        set elo [expr {600 - (($a - 150) / 100.0) * 200}]
    } else {
        set elo [expr {max(300, 400 - ($a - 250) * 0.4)}]
    }
    return [expr {round(max(300, min(2900, $elo)))}]
}

proc ::crclass::estimateElo {accuracy avgCpl} {
    set fromAcpl [eloFromAcpl $avgCpl]
    set accAdjust [expr {max(-100.0, min(100.0, ($accuracy - 75) * 10))}]
    return [expr {round(max(300, min(2900, $fromAcpl + $accAdjust * 0.2)))}]
}

# estimateGamePerformance. opponentRating "" => no anchor (own strength only).
# opponentRd "" => 350 (unrated), which drives oppConf to 0 and therefore
# reproduces the own-strength result - pass 100 for an established rating.
proc ::crclass::estimateGamePerformance {args} {
    array set A {accuracy 0 acpl 0 opponentRating "" opponentRd "" score 0.5}
    foreach {k v} $args {
        if {[string index $k 0] eq "-"} { set k [string range $k 1 end] }
        set A($k) $v
    }
    set fromAcpl [eloFromAcpl $A(acpl)]
    set accNudge [expr {max(-100.0, min(100.0, ($A(accuracy) - 75) * 10))}]
    set ownStrength [expr {$fromAcpl + 0.2 * $accNudge}]
    if {$A(opponentRating) eq ""} {
        return [expr {round(max(300, min(2900, $ownStrength)))}]
    }
    set rd $A(opponentRd)
    if {$rd eq ""} { set rd 350 }
    set oppConf [expr {max(0.0, min(1.0, (350 - $rd) / 250.0))}]
    if {$A(score) == 1} {
        set result 200
    } elseif {$A(score) == 0} {
        set result -200
    } else {
        set result 0
    }
    set oppPerf [expr {$A(opponentRating) + $result}]
    set delta [expr {max(-600.0, min(600.0, $oppPerf - $ownStrength))}]
    set oppPerfClamped [expr {$ownStrength + $delta}]
    set blend [expr {$ownStrength * (1 - 0.35 * $oppConf) + $oppPerfClamped * (0.35 * $oppConf)}]
    return [expr {round(max(300, min(2900, $blend)))}]
}

# CAPS-style game accuracy - port of chess/accuracy.ts:gameAccuracy.
# points: list of {acc winPct isBook}. Book moves are dropped entirely.
proc ::crclass::stdev_ {xs} {
    set n [llength $xs]
    if {$n == 0} { return 0.0 }
    set sum 0.0
    foreach x $xs { set sum [expr {$sum + $x}] }
    set mean [expr {$sum / $n}]
    set var 0.0
    foreach x $xs { set var [expr {$var + ($x - $mean) * ($x - $mean)}] }
    return [expr {sqrt($var / $n)}]
}

proc ::crclass::gameAccuracy {points} {
    set accs {}
    set wins {}
    foreach p $points {
        lassign $p acc winPct isBook
        if {$isBook} continue
        lappend accs [expr {max(0.0, min(100.0, $acc))}]
        lappend wins $winPct
    }
    set n [llength $accs]
    if {$n == 0} { return 0.0 }

    set windowSize [expr {int(max(2, min(8, ceil($n / 10.0))))}]
    set half [expr {$windowSize / 2}]

    set weights {}
    for {set i 0} {$i < $n} {incr i} {
        set start [expr {max(0, $i - $half)}]
        set end [expr {min($n, $start + $windowSize)}]
        set win [lrange $wins $start [expr {$end - 1}]]
        lappend weights [expr {max(0.5, min(4.0, [stdev_ $win]))}]
    }
    set wSum 0.0
    foreach w $weights { set wSum [expr {$wSum + $w}] }
    if {$wSum == 0.0} { set wSum 1.0 }
    set accSum 0.0
    for {set i 0} {$i < $n} {incr i} {
        set accSum [expr {$accSum + [lindex $weights $i] * [lindex $accs $i]}]
    }
    set volMean [expr {$accSum / $wSum}]

    set sorted [lsort -real $accs]
    set floor 0.0
    if {$n >= 5} { set floor [lindex $sorted 2] }
    set inv 0.0
    foreach a $accs {
        set v [expr {max(1.0, max($a, $floor))}]
        set inv [expr {$inv + 1.0 / $v}]
    }
    set harmonic [expr {$n / $inv}]

    set blend [expr {0.6 * $volMean + 0.4 * $harmonic}]
    set shifted [expr {$blend + max(0.0, 4.0 * pow(1.0 - $blend / 100.0, 1.5))}]
    return [expr {max(0.0, min(100.0, $shifted))}]
}

# keyMoments.ts:extractKeyMoments. moves is a list of dicts with keys
# ply classification eval_before_cp eval_after_cp san fen_before fen_after
# centipawn_loss best_move_san best_pv.
proc ::crclass::extractKeyMoments {moves {max 5}} {
    variable CLASS_WEIGHT
    set cands {}
    foreach m $moves {
        set cls [dict get $m classification]
        if {![info exists CLASS_WEIGHT($cls)]} continue
        set w $CLASS_WEIGHT($cls)
        set ply [dict get $m ply]
        set side [expr {$ply % 2 == 1 ? "white" : "black"}]
        set eb [expr {[dict exists $m eval_before_cp] ? [dict get $m eval_before_cp] : 0}]
        set ea [expr {[dict exists $m eval_after_cp] ? [dict get $m eval_after_cp] : 0}]
        set wpBw [cpToWinPct $eb]
        set wpAw [cpToWinPct $ea]
        set wpB [expr {$side eq "white" ? $wpBw : 100 - $wpBw}]
        set wpA [expr {$side eq "white" ? $wpAw : 100 - $wpAw}]
        set delta [expr {abs($wpB - $wpA)}]
        set cpLoss [dict get $m centipawn_loss]
        set cpComp [expr {min(600, $cpLoss)}]
        set score [expr {$cpComp + 60 * $w + 2 * $delta}]
        lappend cands [dict create ply $ply side $side san [dict get $m san] \
            fen_before [dict get $m fen_before] fen_after [dict get $m fen_after] \
            classification $cls cp_loss $cpLoss win_pct_delta $delta \
            best_san [expr {[dict exists $m best_move_san] ? [dict get $m best_move_san] : ""}] \
            best_pv [expr {[dict exists $m best_pv] ? [dict get $m best_pv] : ""}] \
            score $score]
    }
    set sorted [lsort -command {apply {{a b} {
        set sa [dict get $a score] ; set sb [dict get $b score]
        if {$sa > $sb} { return -1 }
        if {$sa < $sb} { return 1 }
        return 0
    }}} $cands]
    set picked {}
    foreach c $sorted {
        set skip 0
        foreach p $picked {
            if {abs([dict get $p ply] - [dict get $c ply]) <= 4} { set skip 1 ; break }
        }
        if {$skip} continue
        lappend picked $c
        if {[llength $picked] >= $max} break
    }
    return [lsort -integer -increasing -command {apply {{a b} {expr {[dict get $a ply] - [dict get $b ply]}}}} $picked]
}

# refineClassification - the chess.com label rules. Args:
#   -base -isBest -cpLoss -fenBefore -fenAfter -sideToMove
#   -playerEvalBeforeCp -playerEvalAfterCp -ply -legalMoveCount
#   -candidatePlayerCps (list, player's perspective, best first)
#   -pvAfterPlayed (list of UCI moves from fenAfter; optional)
#   -inBook (0/1, optional)

proc ::crclass::_pieceValue {p} {
    switch -- [string tolower $p] {
        p { return 1 }
        n - b { return 3 }
        r { return 5 }
        q { return 9 }
        default { return 0 }
    }
}

# A capture that simply takes a piece standing there for free is the obvious
# move, not a great one: the opponent gave it away on the previous ply.
proc ::crclass::isFreeCapture {fen uci} {
    # NB: no early `return` inside the catch body - Tcl's catch swallows the
    # TCL_RETURN code and the value is lost, so the proc would answer 0 always.
    set out 0
    if {[catch {
        set pos [::crboard::fromFen $fen]
        set to [::crboard::sqIndex [string range $uci 2 3]]
        set victim [lindex [dict get $pos board] $to]
        if {$victim ne ""} {
            set gain [::crboard::see $pos $to]
            set out [expr {$gain >= [_pieceValue $victim] - 1}]
        }
    } err]} {
        set out 0
    }
    return $out
}

proc ::crclass::refineClassification {args} {
    variable BOOK_PLIES
    array set A {
        base best isBest 0 cpLoss 0 fenBefore "" fenAfter "" sideToMove white
        playerEvalBeforeCp 0 playerEvalAfterCp 0 ply 1 legalMoveCount 20
        candidatePlayerCps {} pvAfterPlayed {} inBook "" playedUci "" winDrop 0
    }
    foreach {k v} $args {
        if {[string index $k 0] eq "-"} { set k [string range $k 1 end] }
        set A($k) $v
    }

    if {$A(legalMoveCount) == 1} { return forced }

    if {$A(inBook) ne ""} {
        set isBookPosition $A(inBook)
    } else {
        set isBookPosition [expr {$A(ply) <= $BOOK_PLIES}]
    }
    set winDropApprox [expr {$A(base) eq "blunder" || $A(base) eq "mistake"}]
    if {$isBookPosition && !$winDropApprox} { return book }

    if {$A(isBest) && $A(ply) > $BOOK_PLIES && $A(playerEvalBeforeCp) <= 500 &&
        $A(playerEvalAfterCp) >= -50 && $A(cpLoss) <= 20} {
        set sacrificed [::crboard::hangingMaterial $A(fenBefore) $A(fenAfter) $A(sideToMove)]
        if {$sacrificed >= 2} {
            if {![isTrivialRecapture $A(sideToMove) $A(fenBefore) $A(pvAfterPlayed) $A(fenAfter)]} {
                return brilliant
            }
        }
    }

    if {$A(ply) > $BOOK_PLIES} {
        set cands $A(candidatePlayerCps)
        if {$A(isBest) && [llength $cands] >= 2} {
            set top [lindex $cands 0]
            set second [lindex $cands 1]
            # ... but not when the move is just picking up a piece the opponent
            # left hanging: that is an obvious recapture, however wide the
            # MultiPV gap, and calling it "great" teaches nothing.
            # A wide gap only means something if the mover is still in the game:
            # when every alternative is already losing, the "only move" is a
            # forced retreat, not a great move - and taking material the opponent
            # left hanging is obvious, not great.
            if {$top - $second >= 200 && $A(playerEvalAfterCp) >= -200 \
                && $A(playerEvalAfterCp) >= $A(playerEvalBeforeCp) - 20 \
                && ![isFreeCapture $A(fenBefore) $A(playedUci)]} {
                return great
            }
        }
        if {$A(isBest) && $A(playerEvalBeforeCp) <= -150 && $A(playerEvalAfterCp) >= -50} { return great }
    }

    # A three-pawn loss in a game that was still undecided is a blunder even when
    # the win-chance drop rounds just under the threshold. The two scales
    # disagree near the ends of the curve: a queen going for a rook can read as
    # a 19-point swing at one depth and a 24-point swing at another, and the
    # board loss is the fact that does not move.
    if {!$A(isBest) && $A(ply) > $BOOK_PLIES && $A(cpLoss) >= 300 && $A(winDrop) >= 12 &&
        abs($A(playerEvalBeforeCp)) < 500} {
        return blunder
    }

    set isAtLeastInaccuracy [expr {[lsearch -exact {inaccuracy mistake blunder} $A(base)] >= 0}]
    if {$isAtLeastInaccuracy} {
        if {$A(playerEvalBeforeCp) >= 150 && $A(playerEvalAfterCp) < 50} { return miss }
        if {[isMateCp $A(playerEvalBeforeCp)] && $A(playerEvalBeforeCp) > 0 &&
            ![isMateCp $A(playerEvalAfterCp)]} { return miss }
    }
    return $A(base)
}

# isTrivialRecapture (classifier.ts:152): does the engine's PV simply trade
# back, restoring the pre-move material balance within a pawn?
proc ::crclass::_balanceOf {fen side} {
    lassign [::crboard::material [::crboard::fromFen $fen]] w b
    if {$side eq "white"} { return [expr {$w - $b}] }
    return [expr {$b - $w}]
}

proc ::crclass::isTrivialRecapture {sideToMove fenBefore pv fenAfterPlayed} {
    # No early `return` inside the catch body: catch swallows TCL_RETURN, so the
    # proc would answer 0 for every move - which is exactly what it used to do,
    # silently disabling the brilliant-move guard that calls it.
    set balanceBefore [_balanceOf $fenBefore $sideToMove]
    if {[llength $pv] < 1} { return 0 }
    set out 0
    if {[catch {
        set pos [::crboard::fromFen $fenAfterPlayed]
        set first [lindex $pv 0]
        set to [::crboard::sqIndex [string range $first 2 3]]
        if {[lindex [dict get $pos board] $to] ne ""} {
            set pos [::crboard::makeMove $pos $first]
            foreach uci [lrange $pv 1 3] {
                set pos [::crboard::makeMove $pos $uci]
            }
            set balanceAfter [_balanceOf [::crboard::toFen $pos] $sideToMove]
            set out [expr {($balanceBefore - $balanceAfter) <= 1}]
        }
    } err]} {
        set out 0
    }
    return $out
}

# ---- game phases -----------------------------------------------------------
#
# Opening -> middlegame: BOTH signals must agree. The ECO book has ended AND
# the position has stopped looking like an opening (few majors/minors left, a
# back rank gone sparse, or a high mixedness score). Requiring only the
# positional test would file a decisive opening win under the middlegame - a
# win in the opening is by definition a departure from book - while requiring
# only the book would keep a 25-ply theoretical line in the "opening".
#
# Middlegame -> endgame: only defined when the middlegame exists and starts
# earlier, so the three phases are ordered and never overlap. Two textbook
# triggers: 26 points of material left on the board with the queens off
# (Speelman, with pawns counted), or six majors-and-minors still on the board
# (lichess's rule).
#
# A bucket shorter than 4 plies gets no prose at all.

proc ::crclass::_majorsMinors {fen} {
    set n 0
    foreach ch [split [lindex [split $fen] 0] ""] {
        switch -- $ch { N - B - R - Q - n - b - r - q { incr n } }
    }
    return $n
}

# Points on the board counting pawns, kings excluded: 1/3/3/5/9.
proc ::crclass::_pointsWithPawns {fen} {
    set tot 0
    foreach ch [split [lindex [split $fen] 0] ""] {
        switch -- $ch {
            P - p { incr tot 1 }
            N - B - n - b { incr tot 3 }
            R - r { incr tot 5 }
            Q - q { incr tot 9 }
        }
    }
    return $tot
}

proc ::crclass::_nonPawnMaterial {fen} {
    set tot 0
    foreach ch [split [lindex [split $fen] 0] ""] {
        switch -- $ch {
            N - B - n - b { incr tot 3 }
            R - r { incr tot 5 }
            Q - q { incr tot 9 }
        }
    }
    return $tot
}

proc ::crclass::_queensOff {fen} {
    set board [lindex [split $fen] 0]
    return [expr {[string first "Q" $board] < 0 && [string first "q" $board] < 0}]
}

# lichess backrankSparse: fewer than four of your own pieces on your back rank.
proc ::crclass::_backrankSparse {fen} {
    set board [dict get [::crboard::fromFen $fen] board]
    set w 0 ; set b 0
    for {set f 0} {$f < 8} {incr f} {
        if {[lindex $board $f] ne ""} { incr w }
        if {[lindex $board [expr {56 + $f}]] ne ""} { incr b }
    }
    return [expr {$w < 4 || $b < 4}]
}

# lichess mixedness: score every 2x2 window (files a-g, ranks 1-7) for pieces
# of the two colours sitting in each other's space. Ported from Divider.scala.
proc ::crclass::_mixedScore {y white black} {
    switch -- $white {
        0 {
            switch -- $black {
                1 { return [expr {1 + $y}] }
                2 { return [expr {$y < 6 ? 2 + (6 - $y) : 0}] }
                3 - 4 { return [expr {$y < 7 ? 3 + (7 - $y) : 0}] }
            }
            return 0
        }
        1 {
            switch -- $black {
                0 { return [expr {1 + (8 - $y)}] }
                1 { return [expr {5 + abs(4 - $y)}] }
                2 { return [expr {4 + (7 - $y)}] }
                3 { return [expr {5 + (7 - $y)}] }
            }
            return 0
        }
        2 {
            switch -- $black {
                0 { return [expr {$y > 2 ? 2 + ($y - 2) : 0}] }
                1 { return [expr {4 + ($y - 1)}] }
                2 { return 7 }
            }
            return 0
        }
        3 {
            switch -- $black {
                0 { return [expr {$y > 1 ? 3 + ($y - 1) : 0}] }
                1 { return [expr {5 + ($y - 1)}] }
            }
            return 0
        }
        4 {
            switch -- $black {
                0 { return [expr {$y > 1 ? 3 + ($y - 1) : 0}] }
            }
            return 0
        }
    }
    return 0
}

proc ::crclass::mixedness {fen} {
    set board [dict get [::crboard::fromFen $fen] board]
    set acc 0
    for {set ry 0} {$ry <= 6} {incr ry} {
        for {set fx 0} {$fx <= 6} {incr fx} {
            set w 0 ; set b 0
            foreach sq [list [expr {$ry*8 + $fx}] [expr {$ry*8 + $fx + 1}] \
                             [expr {($ry+1)*8 + $fx}] [expr {($ry+1)*8 + $fx + 1}]] {
                set p [lindex $board $sq]
                if {$p eq ""} continue
                if {[::crboard::colorOf $p] eq "w"} { incr w } else { incr b }
            }
            incr acc [_mixedScore [expr {$ry + 1}] $w $b]
        }
    }
    return $acc
}

# The positional signals lichess uses to say "this is no longer an opening".
proc ::crclass::openingOver {fen} {
    if {[_majorsMinors $fen] <= 10} { return 1 }
    if {[_backrankSparse $fen]} { return 1 }
    if {[mixedness $fen] > 150} { return 1 }
    return 0
}

proc ::crclass::endgameNow {fen} {
    if {[_pointsWithPawns $fen] <= 26 && [_queensOff $fen]} { return 1 }
    if {[_majorsMinors $fen] <= 6} { return 1 }
    return 0
}

proc ::crclass::_phaseStats {moves from to} {
    if {$from > $to} { return "" }
    set slice {}
    foreach m $moves {
        set ply [dict get $m ply]
        if {$ply >= $from && $ply <= $to} { lappend slice $m }
    }
    if {[llength $slice] < 4} { return "" }
    set wPts {} ; set bPts {} ; set wCp {} ; set bCp {}
    foreach m $slice {
        if {[dict exists $m unsearched]} continue
        set cls [dict get $m classification]
        set isBook [expr {[lsearch -exact {book forced} $cls] >= 0}]
        set wpA [cpToWinPct [dict get $m eval_after_cp]]
        set side [dict get $m side]
        set wp [expr {$side eq "white" ? $wpA : 100 - $wpA}]
        set acc [moveAccuracy [dict get $m player_before] [dict get $m player_after]]
        set pt [list $acc $wp $isBook]
        set cpl [cpLossForAcpl [dict get $m player_before] [dict get $m player_after]]
        if {$side eq "white"} {
            lappend wPts $pt
            if {!$isBook} { lappend wCp $cpl }
        } else {
            lappend bPts $pt
            if {!$isBook} { lappend bCp $cpl }
        }
    }
    set sumW 0.0 ; foreach x $wCp { set sumW [expr {$sumW + $x}] }
    set sumB 0.0 ; foreach x $bCp { set sumB [expr {$sumB + $x}] }
    return [dict create \
        from_ply $from to_ply $to plies [llength $slice] \
        accuracy_white [expr {round([gameAccuracy $wPts] * 10) / 10.0}] \
        accuracy_black [expr {round([gameAccuracy $bPts] * 10) / 10.0}] \
        acpl_white [expr {[llength $wCp] ? round($sumW / [llength $wCp]) : 0}] \
        acpl_black [expr {[llength $bCp] ? round($sumB / [llength $bCp]) : 0}]]
}

# Phase boundaries come from the position alone. The opening ends at the first
# ply whose position no longer looks like an opening, and the middlegame at the
# first ply that looks like an endgame. The opening book is deliberately not
# consulted: which book is installed, and whether it covers the line at all,
# must not move the boundaries of the report.
# Any second argument is accepted and ignored - it used to be the book boundary.
proc ::crclass::phaseSplit {moves args} {
    set total [llength $moves]
    if {$total == 0} { return {} }

    set mid ""
    foreach m $moves {
        set ply [dict get $m ply]
        if {[openingOver [dict get $m fen_after]]} { set mid $ply ; break }
    }

    # middlegame -> endgame: only if the middlegame exists and starts earlier.
    set end ""
    if {$mid ne ""} {
        foreach m $moves {
            set ply [dict get $m ply]
            if {$ply <= $mid} continue
            if {[endgameNow [dict get $m fen_after]]} { set end $ply ; break }
        }
    }

    set openingTo [expr {$mid eq "" ? $total : $mid - 1}]
    set midFrom   [expr {$mid eq "" ? $total + 1 : $mid}]
    set midTo     [expr {$mid eq "" ? $total : ($end eq "" ? $total : $end - 1)}]
    set endFrom   [expr {$end eq "" ? $total + 1 : $end}]

    set out [dict create opening [_phaseStats $moves 1 $openingTo] \
                          middlegame [_phaseStats $moves $midFrom $midTo]]
    if {$end ne ""} {
        dict set out endgame [_phaseStats $moves $endFrom $total]
    } else {
        dict set out endgame ""
    }
    return $out
}

# True when the position is checkmate (the side to move has no legal move and is
# in check). A record for the move that delivered mate has nothing to search, so
# without this the engine pass leaves 0.00 behind - which reads as "level" in the
# phase balance and prints "[%eval +0.00]" next to "#".
proc ::crclass::isMatePosition {fen} {
    if {[llength [info commands ::crboard::fromFen]] == 0} { return 0 }
    set pos ""
    catch { set pos [::crboard::fromFen $fen] }
    if {$pos eq ""} { return 0 }
    set side [lindex [split $fen] 1]
    set legal 1
    catch { set legal [llength [::crboard::legalMoves $pos]] }
    if {$legal != 0} { return 0 }
    set check 0
    catch { set check [::crboard::inCheck $pos $side] }
    return $check
}
