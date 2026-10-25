# cr_facts.tcl -- deterministic chess facts for the coach prompt.
#
# The model never analyses: everything it may say about the board comes from
# here. This mirrors Patzer's coach/tactics.ts moveMotifs - what the move does,
# what it attacks, what it leaves hanging, forks, mate threats, and the
# engine's line. Numbers are deliberately scarce: the scoresheet shows those.

namespace eval ::crfacts {
    variable NAME
    array set NAME {p pawn n knight b bishop r rook q queen k king}
    variable VALUE
    array set VALUE {p 1 n 3 b 3 r 5 q 9 k 0}
}

proc ::crfacts::pieceName {p} {
    variable NAME
    if {$p eq ""} { return "" }
    return $NAME([string tolower $p])
}

proc ::crfacts::valueOf {p} {
    variable VALUE
    if {$p eq ""} { return 0 }
    return $VALUE([string tolower $p])
}

proc ::crfacts::sideWord {color} {
    return [expr {$color eq "w" ? "White" : "Black"}]
}

proc ::crfacts::other {color} {
    return [expr {$color eq "w" ? "b" : "w"}]
}

# Does the piece on `from` attack `target`? Geometric, like chess.js
# attackers(): pins are ignored, which is what the motif vocabulary wants.
proc ::crfacts::attacksFrom {pos from target} {
    if {$from == $target} { return 0 }
    set board [dict get $pos board]
    set p [lindex $board $from]
    if {$p eq ""} { return 0 }
    set kind [string tolower $p]
    set df [expr {[::crboard::fileOf $target] - [::crboard::fileOf $from]}]
    set dr [expr {[::crboard::rankOf $target] - [::crboard::rankOf $from]}]
    set adf [expr {abs($df)}]
    set adr [expr {abs($dr)}]
    switch -- $kind {
        p {
            set fwd [expr {[string is upper $p] ? 1 : -1}]
            return [expr {$adf == 1 && $dr == $fwd}]
        }
        n { return [expr {($adf == 1 && $adr == 2) || ($adf == 2 && $adr == 1)}] }
        k { return [expr {$adf <= 1 && $adr <= 1}] }
    }
    set diag [expr {$adf == $adr && $adf > 0}]
    set straight [expr {($df == 0) != ($dr == 0)}]
    if {$kind eq "b" && !$diag} { return 0 }
    if {$kind eq "r" && !$straight} { return 0 }
    if {$kind eq "q" && !($diag || $straight)} { return 0 }
    if {!($diag || $straight)} { return 0 }
    set sf [expr {$df == 0 ? 0 : ($df > 0 ? 1 : -1)}]
    set sr [expr {$dr == 0 ? 0 : ($dr > 0 ? 1 : -1)}]
    set pf [expr {[::crboard::fileOf $from] + $sf}]
    set pr [expr {[::crboard::rankOf $from] + $sr}]
    while {$pf != [::crboard::fileOf $target] || $pr != [::crboard::rankOf $target]} {
        if {[lindex $board [expr {$pr * 8 + $pf}]] ne ""} { return 0 }
        incr pf $sf
        incr pr $sr
    }
    return 1
}

proc ::crfacts::attackersOf {pos sq byColor} {
    set board [dict get $pos board]
    set out {}
    for {set i 0} {$i < 64} {incr i} {
        set p [lindex $board $i]
        if {$p eq ""} continue
        if {[::crboard::colorOf $p] ne $byColor} continue
        if {[attacksFrom $pos $i $sq]} { lappend out [list [pieceName $p] [valueOf $p]] }
    }
    return $out
}

# Pieces of `color` that are attacked and either undefended or attacked by
# something cheaper. Returns a list of {piece square}.
proc ::crfacts::hangingPieces {fen color} {
    set pos [::crboard::fromFen $fen]
    set board [dict get $pos board]
    set them [other $color]
    set out {}
    for {set i 0} {$i < 64} {incr i} {
        set p [lindex $board $i]
        if {$p eq ""} continue
        if {[::crboard::colorOf $p] ne $color} continue
        if {[string tolower $p] eq "k"} continue
        set att [attackersOf $pos $i $them]
        if {![llength $att]} continue
        set def [attackersOf $pos $i $color]
        set minAtt 99
        foreach a $att { if {[lindex $a 1] < $minAtt} { set minAtt [lindex $a 1] } }
        if {![llength $def] || $minAtt < [valueOf $p]} {
            lappend out [list [pieceName $p] [::crboard::sqName $i]]
        }
    }
    return $out
}

# Flip the side to move (a null move) so we can ask "what would they do?".
proc ::crfacts::passTurn {fen} {
    set parts [split $fen]
    lset parts 1 [other [lindex $parts 1]]
    lset parts 3 "-"
    return [join $parts " "]
}

# First mating move for the side to move: {uci san} or "".
proc ::crfacts::mateInOne {fen} {
    set pos [::crboard::fromFen $fen]
    set them [other [dict get $pos side]]
    foreach m [::crboard::legalMoves $pos] {
        set after [::crboard::makeMove $pos $m]
        if {![::crboard::inCheck $after $them]} continue
        if {[llength [::crboard::legalMoves $after]] == 0} {
            set san ""
            if {[llength [info commands sc_pos]]} {
                catch { set san [sc_pos coordToSAN $fen $m] }
            }
            return [list $m $san]
        }
    }
    return ""
}

# Everything about a single move, from the position it was played in.
proc ::crfacts::describeMove {fen uci} {
    set pos [::crboard::fromFen $fen]
    set from [::crboard::sqIndex [string range $uci 0 1]]
    set to   [::crboard::sqIndex [string range $uci 2 3]]
    set board [dict get $pos board]
    set piece [lindex $board $from]
    set victim [lindex $board $to]
    set ep [dict get $pos ep]
    if {$victim eq "" && $to == $ep && [string tolower $piece] eq "p"} { set victim "p" }
    set after [::crboard::makeMove $pos $uci]
    set mover [dict get $pos side]
    set them [other $mover]
    set home [expr {$mover eq "w" ? 0 : 7}]
    set kind [string tolower $piece]
    set check [::crboard::inCheck $after $them]
    return [dict create \
        piece [pieceName $piece] \
        from [::crboard::sqName $from] to [::crboard::sqName $to] \
        capture [pieceName $victim] capture_value [valueOf $victim] \
        check $check \
        mate [expr {$check && [llength [::crboard::legalMoves $after]] == 0}] \
        castle [expr {$kind eq "k" && abs($to - $from) == 2}] \
        promo [expr {[string length $uci] > 4}] \
        develops [expr {($kind eq "n" || $kind eq "b") && [::crboard::rankOf $from] == $home && [::crboard::rankOf $to] != $home}] \
        side [sideWord $mover]]
}

# The most valuable thing the side to move can win (piece, square, value).
proc ::crfacts::biggestTarget {fen} {
    set pos [::crboard::fromFen $fen]
    set board [dict get $pos board]
    set best ""
    set bestVal 0
    set seen {}
    foreach m [::crboard::legalMoves $pos] {
        set to [::crboard::sqIndex [string range $m 2 3]]
        set victim [lindex $board $to]
        if {$victim eq ""} {
            if {$to != [dict get $pos ep]} continue
            set victim p
        }
        if {[lsearch -exact $seen $to] >= 0} continue
        lappend seen $to
        set v [::crboard::see $pos $to]
        if {$v > $bestVal} {
            set bestVal $v
            set best [dict create square [::crboard::sqName $to] piece [pieceName $victim] value $v]
        }
    }
    return $best
}


# The piece set, so the model cannot invent a piece that isn't there. Pawns are
# counted, not located - a full pawn list is noise the coach never needs.
proc ::crfacts::inventoryLine {fen color} {
    set pos [::crboard::fromFen $fen]
    set board [dict get $pos board]
    set pieces {}
    set pawns 0
    for {set i 0} {$i < 64} {incr i} {
        set p [lindex $board $i]
        if {$p eq ""} continue
        if {[::crboard::colorOf $p] ne $color} continue
        if {[string tolower $p] eq "p"} { incr pawns; continue }
        lappend pieces [list [valueOf $p] $i "[pieceName $p] on [::crboard::sqName $i]"]
    }
    # king, queen, rooks, bishops, knights - the way a player would list them
    set pieces [lsort -command {apply {{a b} {
        set va [lindex $a 0]; set vb [lindex $b 0]
        if {$va != $vb} { return [expr {$vb - $va}] }
        return [expr {[lindex $a 1] - [lindex $b 1]}]
    }}} $pieces]
    set named {}
    foreach e $pieces { lappend named [lindex $e 2] }
    set pieces $named
    set s "[sideWord $color] has [join $pieces {, }]"
    if {$pawns == 1} {
        append s ", and one pawn"
    } elseif {$pawns > 1} {
        append s ", and $pawns pawns"
    } elseif {![llength $pieces]} {
        set s "[sideWord $color] has only the king"
    }
    return $s
}


# Who may still castle, so the coach cannot invent a castling plan for a side
# that lost the right twenty moves ago.

# ---- rule-state facts ------------------------------------------------------
# Three things a coach can invent and cannot see: en passant, repetition and
# the fifty-move clock. All three are computed, never inferred.

# A position signature: everything that makes two positions "the same" for
# repetition. The move counters are deliberately dropped.
proc ::crfacts::sig {fen} {
    lassign [split $fen] board side castle ep
    return "$board $side $castle $ep"
}

# Always stated, positive or negative: the absence of the line is what let the
# model invent rule states in the first place.
proc ::crfacts::epLine {fen} {
    set ep [lindex [split $fen] 3]
    if {$ep eq "" || $ep eq "-"} { return "en passant: none available" }
    set pos [::crboard::fromFen $fen]
    set to [::crboard::sqIndex $ep]
    if {[lindex [dict get $pos board] $to] ne ""} { return "en passant: none available" }
    set can 0
    if {![catch {
        foreach m [::crboard::legalMoves $pos] {
            if {[string range $m 2 3] eq $ep} { set can 1 ; break }
        }
    }]} {}
    if {$can} { return "en passant: a pawn can be captured on $ep" }
    return "en passant: none available"
}

# Always stated, with the remainder, so the model can tell how far away it is.
proc ::crfacts::clockLine {fen} {
    set half [lindex [split $fen] 4]
    if {![string is integer -strict $half]} { set half 0 }
    set left [expr {100 - $half}]
    if {$left <= 0} {
        return "fifty-move rule: the hundred-ply count is complete, either side may claim a draw"
    }
    set leftWord [expr {$left == 1 ? "ply" : "plies"}]
    return "fifty-move rule: $half plies since the last capture or pawn move; $left more $leftWord would allow a draw claim"
}

proc ::crfacts::repetitionLine {count} {
    if {$count eq ""} { return "repetition: not available for this position" }
    if {$count <= 1} { return "repetition: this position has not occurred before" }
    if {$count == 2} { return "repetition: this position has now occurred twice" }
    return "repetition: this position has occurred $count times, so a draw can be claimed"
}

# Repetition count for the position on the board, from the game's main line.
# Returns "" when the board is on a variation (the main line no longer matches)
# so the caller can say "not available" instead of guessing.
proc ::crfacts::repFromMainline {fen ply} {
    if {[llength [info commands sc_game]] == 0} { return "" }
    if {[catch { set ml [sc_game UCI_mainLine] }]} { return "" }
    set parts [split $ml]
    set idx [lsearch -exact $parts "moves"]
    if {$idx < 0} { return "" }
    set startFen {rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1}
    if {[lindex $parts 1] eq "fen"} {
        set startFen [join [lrange $parts 2 [expr {$idx - 1}]] " "]
    }
    set moves [lrange $parts [expr {$idx + 1}] end]
    set pos [::crboard::fromFen $startFen]
    set seen [dict create]
    dict incr seen [sig [::crboard::toFen $pos]]
    for {set k 0} {$k < $ply && $k < [llength $moves]} {incr k} {
        if {[catch { set pos [::crboard::makeMove $pos [lindex $moves $k]] }]} { return "" }
        dict incr seen [sig [::crboard::toFen $pos]]
    }
    if {[sig [::crboard::toFen $pos]] ne [sig $fen]} { return "" }
    return [dict get $seen [sig $fen]]
}

proc ::crfacts::castlingLine {fen} {
    set rights [lindex [split $fen] 2]
    set w {} ; set b {}
    if {[string first "K" $rights] >= 0} { lappend w kingside }
    if {[string first "Q" $rights] >= 0} { lappend w queenside }
    if {[string first "k" $rights] >= 0} { lappend b kingside }
    if {[string first "q" $rights] >= 0} { lappend b queenside }
    # Always stated, in the negative when it applies: a fact that is absent
    # leaves the model free to invent the right, which is exactly what it did.
    set out {}
    foreach {who lst} [list White $w Black $b] {
        if {[llength $lst]} {
            lappend out "$who may still castle [join $lst { and }]"
        } else {
            lappend out "$who has no castling rights"
        }
    }
    return "castling: [join $out {; }]"
}

proc ::crfacts::materialLine {fen} {
    lassign [::crboard::material [::crboard::fromFen $fen]] w b
    if {$w == $b} { return "material is level" }
    set diff [expr {abs($w - $b)}]
    set who [expr {$w > $b ? "White" : "Black"}]
    # "Black is 8 pawns up" is arithmetic the reader reads as a bug when the
    # queen is simply gone. Name what is actually missing from the board.
    set behind [expr {$w > $b ? "Black" : "White"}]
    set board [dict get [::crboard::fromFen $fen] board]
    array set seen {q 0 r 0 b 0 n 0 p 0}
    foreach p $board {
        if {$p eq ""} continue
        if {[::crboard::colorOf $p] ne [expr {$w > $b ? "b" : "w"}]} continue
        set k [string tolower $p]
        if {[info exists seen($k)]} { incr seen($k) }
    }
    set gone {}
    foreach {k n full} {q 1 queen r 2 rook b 2 bishop n 2 knight p 8 pawn} {
        set short [expr {$n - $seen($k)}]
        if {$short <= 0} continue
        if {$short == 1} {
            lappend gone "a $full"
        } else {
            lappend gone "$short ${full}s"
        }
    }
    if {[llength $gone]} {
        return "material: $who is $diff points up, and $behind has lost [join [lrange $gone 0 1] { and }]"
    }
    return "material: $who is $diff points up"
}

proc ::crfacts::namesOf {list} {
    set out {}
    foreach e $list { lappend out "the [lindex $e 0] on [lindex $e 1]" }
    return $out
}


# What the engine's move achieves, in the same vocabulary - so the facts can
# say "better was Rc1, which defends the bishop" rather than naming a move.
proc ::crfacts::castleAfter {fen uci mover} {
    if {[catch { set after [::crboard::makeMove [::crboard::fromFen $fen] $uci] }]} { return 0 }
    # after the move it is the opponent's turn: pass it back to ask "can I castle?"
    set mine [::crboard::fromFen [passTurn [::crboard::toFen $after]]]
    set king [expr {$mover eq "w" ? "e1" : "e8"}]
    set short "$king[expr {$mover eq "w" ? "g1" : "g8"}]"
    set long  "$king[expr {$mover eq "w" ? "c1" : "c8"}]"
    foreach m [::crboard::legalMoves $mine] {
        if {$m eq $short || $m eq $long} { return 1 }
    }
    return 0
}


# Pieces off their home squares: the cheap, checkable proxy for development.
proc ::crfacts::development {fen color} {
    set pos [::crboard::fromFen $fen]
    set board [dict get $pos board]
    # a1 b1 c1 d1 f1 g1 h1 / a8 .. h8, minus the king's square (e1/e8)
    set home [expr {$color eq "w" ? {0 1 2 3 5 6 7} : {56 57 58 59 61 62 63}}]
    set n 0
    # a piece counts as developed once it has left a home square
    for {set i 0} {$i < 64} {incr i} {
        set p [lindex $board $i]
        if {$p eq ""} continue
        if {[::crboard::colorOf $p] ne $color} continue
        set k [string tolower $p]
        if {$k ne "n" && $k ne "b" && $k ne "r" && $k ne "q"} continue
        if {[lsearch -exact $home $i] >= 0} continue
        incr n
    }
    return $n
}


# Legal-move count for a colour, as a rough activity score. For the side not to
# move the position is flipped with a null move; if that leaves the flipped side
# in check the count would only be check evasions, so it returns -1 (unknown).
proc ::crfacts::mobility {fen color} {
    # No `return` inside the catch body: Tcl swallows TCL_RETURN, and the proc
    # would answer -1 every time (this bit twice already in this file).
    set out -1
    if {[catch {
        set pos [::crboard::fromFen $fen]
        if {[dict get $pos side] ne $color} {
            set pos [::crboard::fromFen [passTurn $fen]]
            if {[::crboard::inCheck $pos $color]} {
                set out -1
            } else {
                set out [llength [::crboard::legalMoves $pos]]
            }
        } else {
            set out [llength [::crboard::legalMoves $pos]]
        }
    } err]} {
        set out -1
    }
    return $out
}

proc ::crfacts::castled {fen color} {
    set pos [::crboard::fromFen $fen]
    set board [dict get $pos board]
    set kingSq [expr {$color eq "w" ? 6 : 62}]
    set kingSq2 [expr {$color eq "w" ? 2 : 58}]
    foreach sq [list $kingSq $kingSq2] {
        if {[string tolower [lindex $board $sq]] eq "k" && [::crboard::colorOf [lindex $board $sq]] eq $color} { return 1 }
    }
    return 0
}

# When material and the engine disagree about who is better, say so and say
# why: a two-pawn lead that the engine scores against you is development and
# king safety, and that is exactly the kind of thing a reader cannot see from
# the material count alone.
proc ::crfacts::materialEvalNote {m} {
    if {![dict exists $m eval_after_cp] || ![dict exists $m fen_after]} { return "" }
    set ea [dict get $m eval_after_cp]
    if {[catch { lassign [::crboard::material [::crboard::fromFen [dict get $m fen_after]]] w b }]} { return "" }
    set diff [expr {$w - $b}]
    if {$diff == 0 || $ea == 0} { return "" }
    # both expressed from White's side; opposite signs means a real disagreement
    if {(($diff > 0) && ($ea > 0)) || (($diff < 0) && ($ea < 0))} { return "" }
    if {abs($ea) < 100} { return "" }
    set matWho [expr {$diff > 0 ? "White" : "Black"}]
    set matAmt [expr {abs($diff)}]
    set evWho [expr {$ea > 0 ? "White" : "Black"}]
    set dw [development [dict get $m fen_after] w]
    set db [development [dict get $m fen_after] b]
    set cw [castled [dict get $m fen_after] w]
    set cb [castled [dict get $m fen_after] b]
    set why {}
    if {$dw != $db} {
        set ahead [expr {$dw > $db ? "White" : "Black"}]
        set gap [expr {abs($dw - $db)}]
        lappend why "$ahead has $gap more pieces developed"
    }
    if {$cw != $cb} {
        set done [expr {$cw ? "White" : "Black"}]
        set not [expr {$cw ? "Black" : "White"}]
        lappend why "$done has castled while $not has not"
    }
    # Activity: the part development and castling do not cover.
    if {[dict exists $m fen_after]} {
        set mw [mobility [dict get $m fen_after] w]
        set mb [mobility [dict get $m fen_after] b]
        if {$mw >= 0 && $mb >= 0 && abs($mw - $mb) >= 5} {
            set ahead [expr {$mw > $mb ? "White" : "Black"}]
            lappend why "$ahead has [expr {abs($mw - $mb)}] more legal moves"
        }
    }
    set note "material says $matWho is $matAmt pawns up, yet the engine still has $evWho ahead"
    if {[llength $why] == 1} {
        append note " - [lindex $why 0]"
    } elseif {[llength $why] > 1} {
        append note " - [join [lrange $why 0 end-1] {, }], and [lindex $why end]"
    }
    return $note
}

# What a move achieves, as a short list of phrases. Used for the engine's move
# ("better was X: it protects ... and develops ...") and, by difference, for the
# contrast with the move that was actually played.
proc ::crfacts::gainsOf {fen uci mover} {
    set them [other $mover]
    set before [::crboard::fromFen $fen]
    if {[catch { set after [::crboard::makeMove $before $uci] }]} { return {} }
    set fa [::crboard::toFen $after]
    set d [describeMove $fen $uci]
    set out {}

    set mineBefore [hangingPieces $fen $mover]
    set mineAfter [hangingPieces $fa $mover]
    set theirsBefore [hangingPieces $fen $them]
    set theirsAfter [hangingPieces $fa $them]

    # material won by a capture
    if {[dict get $d capture] ne ""} {
        if {[catch { set v [::crboard::see $before [::crboard::sqIndex [dict get $d to]]] }]} { set v 0 }
        if {$v >= 1} { lappend out "wins the [dict get $d capture] on [dict get $d to]" }
    }

    # pieces of ours that stop being hangable
    set fromSq [dict get $d from]
    set toSq [dict get $d to]
    foreach e $mineBefore {
        if {[lindex $e 1] eq $fromSq} continue
        if {[lsearch -exact $mineAfter $e] >= 0} continue
        set sq [::crboard::sqIndex [lindex $e 1]]
        set stillAttacked [expr {[llength [attackersOf $after $sq $them]] > 0}]
        if {$stillAttacked} {
            lappend out "protects the [lindex $e 0] on [lindex $e 1]"
        } else {
            lappend out "takes the pressure off the [lindex $e 0] on [lindex $e 1]"
        }
    }
    # the piece that moved is not "protected" by itself: it walked away
    set wasHanging [expr {[lsearch -exact $mineBefore [list [dict get $d piece] $fromSq]] >= 0}]
    set stillHanging [expr {[lsearch -exact $mineAfter [list [dict get $d piece] $toSq]] >= 0}]
    if {$wasHanging && !$stillHanging} {
        lappend out "moves the [dict get $d piece] out of danger"
    }

    # enemy pieces that become takeable or attacked
    set hits {}
    foreach e $theirsAfter {
        if {[lsearch -exact $theirsBefore $e] >= 0} continue
        lappend hits $e
    }
    if {[llength $hits]} {
        lappend out "threatens [join [namesOf $hits] { and }]"
    }

    if {[dict get $d develops]} { lappend out "develops a piece" }
    # Only with the right still on the board: the legality test alone has been
    # wrong in the wild, and a false "can castle" is what the reader noticed.
    set rights [lindex [split $fen] 2]
    set hasRight [expr {$mover eq "w" ? ([string first "K" $rights] >= 0 || [string first "Q" $rights] >= 0) : ([string first "k" $rights] >= 0 || [string first "q" $rights] >= 0)}]
    if {$hasRight && ![dict get $d castle] && [castleAfter $fen $uci $mover]} {
        lappend out "lets [sideWord $mover] castle next move"
    }
    if {[dict get $d mate]} { lappend out "is checkmate" }

    set allowsMate [mateInOne $fa]
    if {$allowsMate eq ""} {
        set mt [mateInOne [passTurn $fa]]
        if {$mt ne ""} {
            set san [lindex $mt 1]
            lappend out [expr {$san ne "" ? "threatens mate with $san" : "threatens mate"}]
        }
    }
    return $out
}

# Legal destinations per square for one side's bishops, rooks and queens.
# Claims like "this frees the bishop" are checkable against this map: a piece
# that was boxed in and now has moves was genuinely freed; a piece that gains
# one square beside the pawn that stepped aside was not.
proc ::crfacts::sliderMap {fen color} {
    set stm [lindex [split $fen] 1]
    if {$stm ne $color} { set fen [::crfacts::passTurn $fen] }
    if {[catch { set pos [::crboard::fromFen $fen] }]} { return {} }
    set board [dict get $pos board]
    array set cnt {}
    for {set i 0} {$i < 64} {incr i} {
        set p [lindex $board $i]
        if {$p eq ""} continue
        if {[::crboard::colorOf $p] ne $color} continue
        set k [string tolower $p]
        if {$k ne "b" && $k ne "r" && $k ne "q"} continue
        set cnt($i) 0
    }
    if {[catch {
        foreach m [::crboard::legalMoves $pos] {
            set f [::crboard::sqIndex [string range $m 0 1]]
            if {[info exists cnt($f)]} { incr cnt($f) }
        }
    }]} { return {} }
    array get cnt
}

# Pieces of the mover's that the move genuinely frees: boxed in before, with
# real scope after. The piece that moved is not counted - it freed itself.
proc ::crfacts::freedPieces {fen uci mover} {
    set d [::crfacts::describeMove $fen $uci]
    set fromSq [::crboard::sqIndex [dict get $d from]]
    set before [::crfacts::sliderMap $fen $mover]
    if {![llength $before]} { return {} }
    if {[catch { set after [::crboard::makeMove [::crboard::fromFen $fen] $uci] }]} { return {} }
    set fa [::crfacts::passTurn [::crboard::toFen $after]]
    set amap [::crfacts::sliderMap $fa $mover]
    if {![llength $amap]} { return {} }
    array set a $amap
    array set b $before
    set out {}
    foreach {sq n} $before {
        if {$sq == $fromSq} continue
        if {![info exists a($sq)]} continue
        set gain [expr {$a($sq) - $n}]
        if {($n == 0 && $a($sq) >= 3) || ($gain >= 5 && $a($sq) >= 5)} {
            set name [::crfacts::pieceOn $fen $sq]
            if {$name ne ""} { lappend out "the $name" }
        }
    }
    return $out
}

# `sq` is a board index, as produced by sliderMap.
proc ::crfacts::pieceOn {fen sq} {
    if {[catch { set pos [::crboard::fromFen $fen] }]} { return "" }
    set p [lindex [dict get $pos board] $sq]
    if {$p eq ""} { return "" }
    return "[::crfacts::pieceName $p] on [::crboard::sqName $sq]"
}

proc ::crfacts::betterMoveClause {fen best {mover "w"}} {
    set gains [gainsOf $fen $best $mover]
    if {![llength $gains]} { return "" }
    return [join [lrange $gains 0 2] { and }]
}

# ---- the motif block -------------------------------------------------------

proc ::crfacts::motifLines {m} {
    set fb [dict get $m fen_before]
    set played [dict get $m played]
    set mover [expr {[dict get $m side] eq "white" ? "w" : "b"}]
    set them [other $mover]
    set lines {}

    set p [describeMove $fb $played]
    set after [::crboard::makeMove [::crboard::fromFen $fb] $played]

    if {[dict get $p mate]} { lappend lines "it is checkmate" }
    if {[dict get $p develops]} { lappend lines "it develops a minor piece" }

    # what the moved piece hits from its new square
    set to [::crboard::sqIndex [dict get $p to]]
    set hits {}
    set board [dict get $after board]
    for {set i 0} {$i < 64} {incr i} {
        set q [lindex $board $i]
        if {$q eq ""} continue
        if {[::crboard::colorOf $q] ne $them} continue
        if {![attacksFrom $after $to $i]} continue
        set defended [expr {[llength [attackersOf $after $i $them]] > 0}]
        if {[string tolower $q] eq "k" || [valueOf $q] > [valueOf [lindex $board $to]] || !$defended} {
            lappend hits [list [pieceName $q] [::crboard::sqName $i]]
        }
    }
    if {[llength $hits] >= 2} {
        lappend lines "it attacks [join [namesOf $hits] { and }] at the same time - a fork"
    } elseif {[llength $hits] == 1 && [dict get $p check]} {
        lappend lines "it attacks [lindex [namesOf $hits] 0] while giving check"
    } elseif {[llength $hits] == 1} {
        lappend lines "it attacks [lindex [namesOf $hits] 0]"
    }

    # hanging before vs after, for both sides
    set mineBefore [hangingPieces $fb $mover]
    set mineAfter [hangingPieces [::crboard::toFen $after] $mover]
    set theirsBefore [hangingPieces $fb $them]
    set theirsAfter [hangingPieces [::crboard::toFen $after] $them]

    # The piece that moved is special: it did not "save" itself by leaving a
    # square, and it is not "left hanging" on a square it never stood on.
    set fromSq [dict get $p from]
    set toSq [dict get $p to]
    set wasHangingAtFrom [expr {[lsearch -exact $mineBefore [list [dict get $p piece] $fromSq]] >= 0}]
    set isHangingAtTo [expr {[lsearch -exact $mineAfter [list [dict get $p piece] $toSq]] >= 0}]
    set newHangs {}
    foreach e $mineAfter {
        if {[lindex $e 1] eq $toSq} continue
        if {[lsearch -exact $mineBefore $e] < 0} { lappend newHangs $e }
    }
    set newSaves {}
    foreach e $mineBefore {
        if {[lindex $e 1] eq $fromSq} continue
        if {[lsearch -exact $mineAfter $e] < 0} { lappend newSaves $e }
    }
    if {$wasHangingAtFrom && !$isHangingAtTo} {
        set escapes [list [list [dict get $p piece] $fromSq]]
    } else {
        set escapes {}
    }
    if {$isHangingAtTo && !$wasHangingAtFrom} {
        lappend newHangs [list [dict get $p piece] $toSq]
    }
    set hitSquares {}
    foreach h $hits { lappend hitSquares [lindex $h 1] }
    set newThreats {}
    foreach e $theirsAfter {
        if {[lsearch -exact $theirsBefore $e] >= 0} continue
        # already reported as a fork/attack target above
        if {[lsearch -exact $hitSquares [lindex $e 1]] >= 0} continue
        lappend newThreats $e
    }

    if {[llength $newHangs]} {
        lappend lines "it leaves [join [namesOf $newHangs] { and }] hanging"
    }
    foreach e $escapes {
        lassign $e epiece esq
        lappend lines "it moves the $epiece on $esq out of danger"
    }
    if {[llength $newSaves]} {
        set afterPos [::crboard::fromFen [::crboard::toFen $after]]
        set stillHit 0
        foreach e $newSaves {
            set sq [::crboard::sqIndex [lindex $e 1]]
            if {[llength [attackersOf $afterPos $sq $them]]} { set stillHit 1 ; break }
        }
        if {$stillHit} {
            lappend lines "it protects [join [namesOf $newSaves] { and }]"
        } else {
            lappend lines "it takes the pressure off [join [namesOf $newSaves] { and }]"
        }
    }
    if {[llength $newThreats]} {
        lappend lines "it now threatens [join [namesOf $newThreats] { and }]"
    }

    # mate motifs
    set fa [::crboard::toFen $after]
    set allowsMate [mateInOne $fa]
    if {$allowsMate ne ""} {
        set san [lindex $allowsMate 1]
        if {$san ne ""} {
            lappend lines "the opponent can now mate in one with $san"
        } else {
            lappend lines "the opponent can now mate in one"
        }
    }
    set theyThreatened [mateInOne [passTurn $fb]]
    if {$theyThreatened ne "" && $allowsMate eq ""} {
        lappend lines "it stops the opponent's mate threat"
    }
    set mateThreat [mateInOne [passTurn $fa]]
    if {$mateThreat ne ""} {
        set san [lindex $mateThreat 1]
        if {$san ne ""} {
            lappend lines "it creates a mate threat with $san"
        } else {
            lappend lines "it creates a mate threat"
        }
    }
    return $lines
}



# The one thing that best explains a move, from the board alone. Deliberately
# conservative: only claims we can prove without deep search.

# "the bishop takes the knight on f6" / "the rook moves from f1 to e1".
# `gerund` gives "taking"/"moving" for sentences that already have a subject.
proc ::crfacts::movePhrase {d {gerund 0}} {
    if {[dict get $d castle]} { return "the king castles" }
    set piece [dict get $d piece]
    set verb [expr {$gerund ? "taking" : "takes"}]
    if {[dict get $d capture] ne ""} {
        return "the $piece $verb the [dict get $d capture] on [dict get $d to]"
    }
    if {$gerund} { return "the $piece moving from [dict get $d from] to [dict get $d to]" }
    return "the $piece moves from [dict get $d from] to [dict get $d to]"
}

proc ::crfacts::moveWhy {m} {
    set fb [dict get $m fen_before]
    set fa [expr {[dict exists $m fen_after] ? [dict get $m fen_after] : ""}]
    if {$fa eq ""} {
        if {[catch { set fa [::crboard::toFen [::crboard::makeMove [::crboard::fromFen $fb] [dict get $m played]]] }]} {
            return ""
        }
    }
    set d [describeMove $fb [dict get $m played]]
    if {[dict get $d mate]} { return "it is checkmate" }
    # what the side to move can win now that the move is on the board
    set t [biggestTarget $fa]
    if {$t ne "" && [dict get $t value] >= 3} {
        return "it leaves the [dict get $t piece] on [dict get $t square] for the opponent to take"
    }
    set mover [expr {[dict get $d side] eq "White" ? "w" : "b"}]
    set mine [hangingPieces $fa $mover]
    foreach e $mine {
        if {[lindex $e 1] eq [dict get $d to]} {
            return "it puts the [lindex $e 0] on [lindex $e 1] where it can be taken"
        }
    }
    return ""
}

# One line about a move for the phase paragraph: what it was, how it was
# judged, and (when it was bad) what the engine wanted instead.
proc ::crfacts::phaseMoveLine {m {opts ""}} {
    set noclass [expr {[lsearch -exact $opts "-noclass"] >= 0}]
    set d [describeMove [dict get $m fen_before] [dict get $m played]]
    set what [movePhrase $d]
    if {[dict get $d check]} { append what " with check" }
    if {[dict get $d promo]} { append what " and promotes" }
    set ply [dict get $m ply]
    set mv [expr {($ply + 1) / 2}]
    set cls [dict get $m classification]
    set line "move $mv, [dict get $d side]: $what"

    set why [moveWhy $m]
    if {$why ne ""} { append line ", and $why" }
    # Only bad moves carry their severity. A good move does not need to be
    # called "great" - the facts have to say what it achieved instead.
    if {!$noclass && [lsearch -exact {inaccuracy mistake miss blunder} $cls] >= 0} {
        append line " ($cls)"
    }

    if {[lsearch -exact {inaccuracy mistake miss blunder} $cls] >= 0} {
        set bs [expr {[dict exists $m best_san] ? [dict get $m best_san] : ""}]
        set bu [expr {[dict exists $m best_uci] ? [dict get $m best_uci] : ""}]
        set mover [expr {[dict get $d side] eq "White" ? "w" : "b"}]
        set bg [expr {$bu ne "" ? [gainsOf [dict get $m fen_before] $bu $mover] : {}}]
        set pg [gainsOf [dict get $m fen_before] [dict get $m played] $mover]
        set bg [lrange $bg 0 2]
        # The reason the engine's move is better is what it does that the play
        # did not. Shared gains are acknowledged ("also") so a reader is not
        # told that only one move protects the pawn when both do.
        set shared {}
        set extras {}
        foreach g $bg { if {[lsearch -exact $pg $g] >= 0} { lappend shared $g } else { lappend extras $g } }
        set phrase ""
        if {[llength $shared] && [llength $extras]} {
            append phrase ": it also [join $shared { and }], and unlike the move played it [join $extras { and }]"
        } elseif {[llength $bg]} {
            append phrase ": it [join $bg {, }]"
        }
        if {$bs ne ""} {
            append line ". Better was $bs$phrase"
        } elseif {$phrase ne ""} {
            append line ". Better was the engine's move$phrase"
        }
        set pv [expr {[dict exists $m best_pv] ? [dict get $m best_pv] : {}}]
        if {[llength $pv] >= 2} {
            append line ". The engine's line: [join [lrange $pv 0 4] { }]"
        }
    }
    return $line
}

# Build the FACTS block for one flagged move.
proc ::crfacts::forMove {m} {
    set lines {}
    set played [dict get $m played]
    set best [dict get $m best_uci]
    set fb [dict get $m fen_before]
    set fa [dict get $m fen_after]

    set p [describeMove $fb $played]
    set what [movePhrase $p]
    if {[dict get $p check]} { append what " with check" }
    if {[dict get $p promo]} { append what " and promotes" }
    # strip only the leading article: "the queen takes the pawn" -> "queen takes the pawn"
    regsub {^the } $what "" what
    lappend lines "played: [dict get $p side]'s $what"

    foreach l [motifLines $m] { lappend lines $l }

    # What the move actually achieved, stated before any alternative. Without
    # this the reader (and the model) infers from "the better move wins the
    # pawn" that the played move did not - which is how a queen capture came to
    # be described as "leaving the pawn untouched".
    set mover [expr {[dict get $m side] eq "white" ? "w" : "b"}]
    set pg [gainsOf $fb $played $mover]
    if {[llength $pg]} {
        lappend lines "what the move played achieved: it [join $pg {, }]"
    }

    # The engine's answer, and its line - for a mistake/miss/blunder the line
    # IS the explanation, so it is always included.
    set line [expr {[dict exists $m best_pv_long] ? [dict get $m best_pv_long] : [dict get $m best_pv]}]
    if {$best ne "" && $best ne $played} {
        set b [describeMove $fb $best]
        # Name the side that makes the alternative. "the pawn taking the knight
        # on e5" left two of three models reading the pawn as White's and
        # asserting a recapture White cannot make.
        set bside [dict get $b side]
        set bpiece [dict get $b piece]
        set bfrom [dict get $b from]
        set bto [dict get $b to]
        if {[dict get $b castle]} {
            set bwhat "$bside's king castles"
        } elseif {[dict get $b capture] ne ""} {
            set bwhat "$bside's $bpiece on $bfrom takes the [dict get $b capture] on $bto"
        } else {
            set bwhat "$bside's $bpiece on $bfrom moves to $bto"
        }
        if {[dict get $b check]} { append bwhat " with check" }
        set bsan [dict get $m best_san]
        set bg [gainsOf $fb $best $mover]
        set shared {}
        set extra {}
        foreach g [lrange $bg 0 2] {
            if {[lsearch -exact $pg $g] >= 0} { lappend shared $g } else { lappend extra $g }
        }
        # The tail must not leave the model to invent a reason. Two cases give
        # it nothing to work with, and both used to produce one: "failed to
        # develop as Nc6 would have" was written for a move that develops, and
        # "would have prevented Ng5" for a pawn push whose own line plays Ng5.
        set tail ""
        if {[llength $shared] && [llength $extra]} {
            set tail ": it also [join $shared { and }], and unlike the move played it [join $extra { and }]"
        } elseif {![llength $bg]} {
            set tail ": the facts here give no reason for the engine's preference"
        } elseif {![llength $extra]} {
            set tail ": it [join [lrange $bg 0 2] {, }], which the move played also does, so the engine's preference is positional and not captured by these facts"
        } else {
            set tail ": it [join [lrange $bg 0 2] {, }]"
        }
        if {$bsan ne ""} {
            lappend lines "better was $bsan - $bwhat$tail"
        } else {
            lappend lines "better was $bwhat$tail"
        }
        if {[llength $line]} {
            lappend lines "the line after that better move runs [join $line { }]"
        }
    } elseif {[llength $line] > 1} {
        lappend lines "the line after the move played runs [join [lrange $line 1 end] { }]"
    }

    # The punishment: what the opponent forces after the move played. It comes
    # from the next analysed position (cr_llm::startProse attaches it), because
    # the engine line from before this move only describes the alternative - and
    # when a blunder ends in mate, the mate IS the reason the label exists.
    if {$best ne "" && $best ne $played && [dict exists $m punish_pv]} {
        set ppv [dict get $m punish_pv]
        if {[llength $ppv]} {
            if {[string match {*#} [string trim [lindex $ppv end]]]} {
                lappend lines "the line after the move played runs [join $ppv { }] and it ends in checkmate"
            } else {
                lappend lines "the line after the move played runs [join $ppv { }]"
            }
        }
    }

    lappend lines [inventoryLine $fb "w"]
    lappend lines [inventoryLine $fb "b"]
    set ruleLines {}
    lappend ruleLines [castlingLine $fb]
    lappend ruleLines [epLine $fb]
    lappend ruleLines [clockLine $fb]
    if {[dict exists $m rep_count]} {
        lappend ruleLines [repetitionLine [dict get $m rep_count]]
    } else {
        set rc [repFromMainline $fb [dict get $m ply]]
        if {$rc ne ""} { lappend ruleLines [repetitionLine $rc] }
    }
    foreach l $ruleLines { if {$l ne ""} { lappend lines $l } }
    # (rule lines are all non-empty by construction now)
    lappend lines [materialLine $fa]
    set note [materialEvalNote $m]
    if {$note ne ""} { lappend lines $note }
    return [join $lines "\n"]
}

# ---- identity and database facts -------------------------------------------

# Name of an ECO code, from scid's own ECO table. Used only where a PGN carries
# a code and no Opening name; the caller labels the result as derived.
proc ::crfacts::ecoName {eco} {
    set summary ""
    catch { set summary [sc_eco summary $eco 0] }
    if {$summary eq ""} { return "" }
    foreach line [split $summary "\n"] {
        if {[regexp {^[A-E][0-9][0-9][a-z]?[0-9]?\s+\[([^\]]+)\]} $line -> name]} {
            return $name
        }
    }
    return ""
}

# One line of database statistics for the current position, or "" when there is
# nothing to say. This runs a filter search over the open database, which
# replaces the user's current filter (scid exposes no save/restore for it), so
# the caller keeps it opt-in and runs it once per review, and it is skipped on
# large bases where the scan would cost more than the review itself.
proc ::crfacts::treeLine {{maxGames 100000}} {
    set base 0
    catch { set base [sc_base current] }
    set n 0
    catch { set n [sc_base numGames $base] }
    if {![string is integer -strict $n] || $n > $maxGames} { return "" }
    if {[catch { sc_filter search $base tree board } err]} { return "" }
    set stats ""
    if {[catch { set stats [sc_tree stats $base "+dbfilter+tree" 0 frequency 4] } err]} {
        return ""
    }
    set games "" ; set score ""
    foreach line [split $stats "\n"] {
        if {[string match "*Move(s)*" $line]} continue
        if {[string match "*TOTAL:*" $line]} continue
        if {[regexp {^\s*[0-9]+:\s+\S.*?([0-9]+):\s+([0-9.]+)%} $line -> g s]} {
            set games $g ; set score $s ; break
        }
    }
    if {$games eq ""} { return "" }
    return "the position occurred in $games games in the open database; White scored $score%"
}

# ---- material swing and forks ----------------------------------------------
# What an error actually cost, and whether the punishment was a fork. A comment
# that says "the rook was taken" when the sequence was a fork winning the
# exchange teaches the wrong lesson: the capture was not the point.

proc ::crfacts::_counts {fen} {
    set out [dict create]
    set pos ""
    catch { set pos [::crboard::fromFen $fen] }
    if {$pos eq ""} { return $out }
    set bd [dict get $pos board]
    for {set sq 0} {$sq < 64} {incr sq} {
        set p [::crboard::pieceAt $bd $sq]
        if {$p eq ""} continue
        set c [::crboard::colorOf $p]
        set t [string tolower [string index $p end]]
        dict incr out "$c$t"
    }
    return $out
}

proc ::crfacts::_swingWord {n} {
    switch -- $n {
        1 { return "a pawn" }
        2 { return "the exchange (a rook for a knight)" }
        3 { return "a piece" }
        5 { return "a rook" }
        9 { return "a queen" }
    }
    return "$n points of material"
}

# Net material won and lost between two positions, from the point of view of the
# side that came out ahead. Returns "" when nothing changed.
proc ::crfacts::materialSwing {fenA fenB} {
    set a ""
    set b ""
    catch { lassign [::crboard::material [::crboard::fromFen $fenA]] wa ba ; set a [list $wa $ba] }
    catch { lassign [::crboard::material [::crboard::fromFen $fenB]] wb bb ; set b [list $wb $bb] }
    if {$a eq "" || $b eq ""} { return "" }
    lassign $a wa ba
    lassign $b wb bb
    set lostW [expr {$wa - $wb}]
    set lostB [expr {$ba - $bb}]
    set delta [expr {$lostB - $lostW}]
    if {$delta == 0} { return "" }
    set side [expr {$delta > 0 ? "White" : "Black"}]
    set n [expr {abs($delta)}]
    return "$side won [_swingWord $n]"
}

# A fork in its useful sense: the move gives check AND attacks another piece
# worth a minor piece or more. Returns "" for anything else.
proc ::crfacts::forkLine {fenBefore uci} {
    if {[string length $uci] < 4} { return "" }
    set pos ""
    catch { set pos [::crboard::fromFen $fenBefore] }
    if {$pos eq ""} { return "" }
    set pos2 ""
    catch { set pos2 [::crboard::makeMove $pos $uci] }
    if {$pos2 eq ""} { return "" }
    set toSq [::crboard::sqIndex [string range $uci 2 3]]
    set bd2 [dict get $pos2 board]
    set piece [::crboard::pieceAt $bd2 $toSq]
    if {$piece eq ""} { return "" }
    set mover [::crboard::colorOf $piece]
    set other [expr {$mover eq "w" ? "b" : "w"}]
    set ksq -1
    catch { set ksq [::crboard::kingSquare $pos2 $other] }
    if {$ksq < 0} { return "" }
    # the move must give check, or it is not a fork in the sense that matters
    set check 0
    catch { set check [::crboard::attacked $pos2 $ksq $mover] }
    if {!$check} { return "" }
    set targets {}
    for {set sq 0} {$sq < 64} {incr sq} {
        if {$sq == $ksq} continue
        set p [::crboard::pieceAt $bd2 $sq]
        if {$p eq ""} continue
        if {[::crboard::colorOf $p] ne $other} continue
        set v 0
        catch { set v [::crfacts::valueOf $p] }
        if {$v < 3} continue
        set hit 0
        catch { set hit [::crfacts::attacksFrom $pos2 $toSq $sq] }
        if {!$hit} continue
        lappend targets "the [string tolower [::crfacts::pieceName $p]] on [::crboard::sqName $sq]"
        if {[llength $targets] >= 2} break
    }
    if {![llength $targets]} { return "" }
    set me "[string tolower [::crfacts::pieceName $piece]] on [::crboard::sqName $toSq]"
    return "the punishment is a fork: the $me checks the king and attacks [join $targets { and }]"
}
