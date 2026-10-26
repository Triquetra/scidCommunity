# Copyright (C) 2026 David Crandall
# SPDX-License-Identifier: GPL-2.0-or-later
#
# comment_facts.tcl -- the board core and the fact lines, in tclsh.
#
#   tclsh tests/tcl/comment_facts.tcl
#
# Two layers are checked here, and the order matters: the facts are only as
# trustworthy as the position they are computed from, so move generation is
# pinned against the published perft counts before any fact line is compared.
# Every fact test uses a move dict of the shape a caller has after an engine
# pass, so what is checked is the contract other code will use.

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
source [file join $root tcl utils chessboard.tcl]
source [file join $root tcl tools comment_facts.tcl]

# ------------------------------------------------------------------- board --

proc perft {pos depth} {
    if {$depth == 0} { return 1 }
    set n 0
    foreach m [::chessboard::legalMoves $pos] {
        if {$depth == 1} {
            incr n
        } else {
            incr n [perft [::chessboard::makeMove $pos $m] [expr {$depth - 1}]]
        }
    }
    return $n
}

puts "board"

set fens {
    {rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1}
    {r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1}
    {8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1}
    {rnbqkbnr/ppp1pppp/8/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 3}
}
foreach fen $fens {
    checkEq "FEN round trip: $fen" \
        [::chessboard::toFen [::chessboard::fromFen $fen]] $fen
}

# Published perft counts. They are the only cheap proof that move generation,
# castling rights, en passant and promotion are all right at the same time.
set startpos [::chessboard::fromFen {rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1}]
checkEq "start position perft 1" [perft $startpos 1] 20
checkEq "start position perft 2" [perft $startpos 2] 400
checkEq "start position perft 3" [perft $startpos 3] 8902

set kiwipete [::chessboard::fromFen {r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1}]
checkEq "Kiwipete perft 1" [perft $kiwipete 1] 48
checkEq "Kiwipete perft 2" [perft $kiwipete 2] 2039

set pos3 [::chessboard::fromFen {8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1}]
checkEq "position 3 perft 1" [perft $pos3 1] 14
checkEq "position 3 perft 2" [perft $pos3 2] 191

proc seeOf {fen sq} {
    return [::chessboard::see [::chessboard::fromFen $fen] [::chessboard::sqIndex $sq]]
}
checkEq "SEE of an undefended rook" [seeOf {4k2r/8/8/8/8/8/8/R6R w - - 0 1} h8] 5
checkEq "SEE of a rook the king defends" [seeOf {6kr/8/8/8/8/8/8/R6R w - - 0 1} h8] 0
checkEq "SEE of a pawn capture" [seeOf {4k3/8/8/3n4/4P3/8/8/4K3 w - - 0 1} d5] 3
checkEq "SEE nets the recapture" [seeOf {3qk3/8/8/3n4/4P3/8/8/4K3 w - - 0 1} d5] 2

# ------------------------------------------------------------------- facts --

puts "facts"

# The move dict a caller has after an engine pass. fen_after is left out on
# purpose: it is a function of fen_before and the move, and the module derives
# it, so a caller that only has the game does not have to build it.
proc moveDict {fen played args} {
    set pos [::chessboard::fromFen $fen]
    set m [dict create fen_before $fen played $played \
        side [expr {[dict get $pos side] eq "w" ? "white" : "black"}] \
        ply 13 classification mistake]
    dict for {k v} $args { dict set m $k $v }
    return $m
}

set mate [::facts::forMove [moveDict {6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1} a1a8]]
checkEq "a mating move is reported as mate, and the block stops there" $mate \
{played: White's rook moves from a1 to a8 with check
it is checkmate
White has rook on a1, king on g1, and 3 pawns
Black has king on g8, and 3 pawns
castling: White has no castling rights; Black has no castling rights
en passant: none available
fifty-move rule: 0 plies since the last capture or pawn move; 100 more plies would allow a draw claim
material: White is 5 points up, and Black has lost a queen and 2 rooks}

# Rule state is stated in the negative too: a fact that is merely absent is
# what lets a comment invent it.
set bare [::facts::forMove [moveDict {4k3/8/8/8/8/8/8/4K3 w - - 99 80} e1d2]]
foreach prefix {castling: en\ passant: fifty-move\ rule: material} {
    check "every block states '$prefix'" \
        [regexp "(?m)^$prefix" $bare]
}
check "no castling rights is said, not implied" \
    [string match {*White has no castling rights; Black has no castling rights*} $bare]
check "the remaining fifty-move plies are counted" \
    [string match {*1 more ply would allow a draw claim*} $bare]

set complete [::facts::forMove [moveDict {4k3/8/8/8/8/8/8/4K3 w - - 100 80} e1d2]]
check "a complete hundred-ply count is a claim" \
    [string match {*fifty-move rule: the hundred-ply count is complete*} $complete]

set rep3 [::facts::forMove [moveDict {4k3/8/8/8/8/8/8/4K3 w - - 0 80} e1d2 rep_count 3]]
check "the caller's repetition count is used verbatim" \
    [string match {*repetition: this position has occurred 3 times*} $rep3]
set rep1 [::facts::forMove [moveDict {4k3/8/8/8/8/8/8/4K3 w - - 0 80} e1d2 rep_count 1]]
check "a first occurrence is stated, not omitted" \
    [string match {*repetition: this position has not occurred before*} $rep1]

set ep [::facts::forMove [moveDict {rnbqkbnr/ppp1pppp/8/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 3} e5d6]]
check "an available en passant capture is named" \
    [string match {*en passant: a pawn can be captured on d6*} $ep]

# Material is stated as what is missing from the board, not as an arithmetic
# difference the reader has to reconcile with the position.
set mat [::facts::forMove [moveDict {rnbqkb1r/ppp2ppp/5n2/3pp3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 0 5} e4d5]]
check "one point of material is not \"1 points\"" \
    [string match {*material: White is 1 point up, and Black has lost a pawn*} $mat]

set alt [::facts::forMove [moveDict \
    {rnbqkb1r/ppp2ppp/5n2/3pp3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 0 5} e4d5 \
    best_uci b1c3 best_san Nc3 best_pv {b1c3 e7e5 g1f3}]]
check "the move played is credited with what it achieved" \
    [string match {*what the move played achieved: it takes the pressure off*} $alt]
check "the engine's alternative names the mover and the difference" \
    [string match {*better was Nc3 - White's knight on b1 moves to c3: it also*} $alt]
check "the engine's line is included" \
    [string match {*the line after that better move runs b1c3 e7e5 g1f3*} $alt]

set dis [::facts::forMove [moveDict \
    {r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/2N2N2/PPPP1PPP/R1BQK2R w KQkq - 6 5} f3e5 \
    best_uci c3d5 best_san Nd5 best_pv {c3d5} eval_after_cp -250]]
check "material and the engine disagreeing is stated, with the reason" \
    [string match {*material says White is 1 pawn up, yet the engine still has Black ahead*} $dis]

# A caller with nothing but the game must still get a usable block.
set minimal [::facts::forMove [dict create \
    fen_before {rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1} \
    played e2e4 side white]]
check "a dict without fen_after, best_* or classification still works" \
    [string match {played: White's pawn moves from e2 to e4*} $minimal]
check "material is stated when the position is level" \
    [string match {*material is level*} $minimal]

# The inventory is the guard against invented pieces: nothing that is not on
# the board may be named in it.
set inv [lsearch -all -inline -regexp [split $bare "\n"] {^(White|Black) has }]
checkEq "the inventory names only what is on the board" [join $inv "|"] \
    {White has king on e1|Black has king on e8}

puts "\n$checks checks, $fails failures"
exit [expr {$fails ? 1 : 0}]
