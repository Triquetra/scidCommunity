# harness.tcl -- runs the review pipeline against a scripted fake engine and
# stubbed scid commands, so the wiring can be verified outside scid.
#   tclsh harness.tcl

set ::scidUserDir /tmp/crtest
file mkdir /tmp/crtest/plugins
# Tk stubs needed before sourcing the GUI module (it installs its menus at load)
if {[llength [info commands winfo]] == 0} { proc winfo {args} { return 0 } }
if {[llength [info commands menu]] == 0} { proc menu {args} { return "" } }
if {[llength [info commands destroy]] == 0} { proc destroy {args} { return "" } }

source [file join [file dirname [info script]] 10_cr_board.tcl]
source [file join [file dirname [info script]] 11_cr_classify.tcl]
source [file join [file dirname [info script]] 12_cr_settings.tcl]
source [file join [file dirname [info script]] 13_cr_engine.tcl]
source [file join [file dirname [info script]] 14_cr_review.tcl]
source [file join [file dirname [info script]] 16_cr_ui.tcl]
source [file join [file dirname [info script]] 17_cr_facts.tcl]
source [file join [file dirname [info script]] 15_cr_llm.tcl]

# ---------------------------------------------------------------- fake game --
set ::G(moves) {e2e4 e7e5 g1f3 b8c6 f1b5 a7a6 b5a4 g8f6 e1g1 f8e7 f1e1 b7b5 a4b3 d7d6 c2c3 e8g8}
set ::G(mainLine) [concat [list "position startpos moves"] $::G(moves)]
set ::G(ply) 0
array set ::CMT {}
array set ::NG {}
array set ::TAGS {White Alpha Black Beta WhiteElo 1800 BlackElo 1750 Result 0-1}

proc sc_game {args} {
    switch -- [lindex $args 0] {
        number      { return 1 }
        eco         { return $::BOOKEND }
        UCI_mainLine { return $::G(mainLine) }
        save        { return "" }
        tags {
            if {[lindex $args 1] eq "get"} { return $::TAGS([lindex $args 2]) }
            return ""
        }
    }
    return ""
}
proc sc_move {args} {
    if {[lindex $args 0] eq "ply"} { set ::G(ply) [lindex $args 1] }
    return ""
}
proc sc_pos {args} {
    switch -- [lindex $args 0] {
        location { return $::G(ply) }
        getComment { return [expr {[info exists ::CMT($::G(ply))] ? $::CMT($::G(ply)) : ""}] }
        setComment { set ::CMT($::G(ply)) [lindex $args 1] ; return "" }
        addNag { lappend ::NG($::G(ply)) [lindex $args 1] ; return "" }
        coordToSAN { return "" }
        fen { return "8/8/8/8/8/8/8/8 w - - 0 1" }
    }
    return ""
}
proc sc_base {args} {
    switch -- [lindex $args 0] {
        isReadOnly { return 0 }
        current    { return 1 }
        numGames   { return 1200 }
    }
    return 1
}
proc sc_var {args} { return 0 }
proc undoFeature {args} { return "" }
namespace eval ::notify {}
proc ::notify::DatabaseModified {args} {}
proc ::notify::PosChanged {args} {}
proc tk_messageBox {args} { puts "MSGBOX: [lindex $args [expr {[lsearch $args -message]+1}]]" ; set ::done 1 ; return ok }
proc winfo {args} { return 0 }
proc update {args} {}
namespace eval ::cr_ui {}
proc ::cr_ui::progressOpen {args} {}
proc ::cr_ui::progressSet {args} {}
proc ::cr_ui::progressClose {} {}
proc ::cr_ui::reportOpen {} { set ::done 1 }
proc ::cr_ui::proseProgress {args} {}
proc ::cr_ui::proseNote {args} {}
namespace eval ::enginecfg {}
namespace eval ::engineNoWin {}
proc ::enginecfg::names {} { return {Stockfish 19 Berserk 14 RubiChess 20240817 (avx2) Lc0 v0.32.1} }
proc ::enginecfg::get {name} { return [list $name $name {} . {} 0 {} 1 {}] }
proc ::engineNoWin::initEngine {id engine cb} { set ::CB($id) $cb ; return 1 }
proc ::engineNoWin::closeEngine {id} { return "" }

# ------------------------------------------------------------ fake engine --
# white-perspective centipawns per position index (0 = start)
set ::EVAL {-20 -20 -20 -20 -20 -20 -20 -20 -20 -20 -20 -20 30 -300 -300 -280 -290}
set ::ENGINE_LOG {}
set ::GAP 30
set ::BOOKEND 12
set ::FORCE_NOTBEST 1

namespace eval ::engine {}
proc ::engine::send {id msg data} {
    lappend ::ENGINE_LOG "$id $msg"
    if {$msg ne "Go"} { return }
    lassign $data position limits
    # position index = number of plies in the string
    set words [split $position " "]
    set nmoves 0
    foreach w $words { if {[regexp {^[a-h][1-8][a-h][1-8]} $w]} { incr nmoves } }
    set cb $::CB($id)
    set depth [lindex [lindex $limits 0] 1]
    set whiteCp [lindex $::EVAL $nmoves]
    set stm [expr {$nmoves % 2 == 0 ? "w" : "b"}]
    set cp [expr {$stm eq "w" ? $whiteCp : -$whiteCp}]

    # best move: normally the move actually played from this position
    set played [lindex $::G(moves) $nmoves]
    set best $played
    if {$id == 21} { set best "d2d4" }   ;# the verifier disagrees, on purpose
    if {$nmoves == 12 && $::FORCE_NOTBEST} { set best "a2a3" }   ;# not the engine's choice
    set pv1 "$best e7e5 g1f3"
    set pv2 "d2d4 d7d5 c2c4"
    set pv3 "c2c4 g8f6 d2d4"
    if {$nmoves == 12} { set cp2 [expr {$cp - $::GAP}] } else { set cp2 [expr {$cp - 30}] }
    set cp3 [expr {$cp - 60}]

    foreach {mpv s pv} [list 1 $cp $pv1 2 $cp2 $pv2 3 $cp3 $pv3] {
        set data2 [list $mpv $depth [expr {$depth+2}] 1000 500 10 0 100 $s cp 0 $pv]
        after 0 [list $cb [list InfoPV $data2]]
    }
    after 0 [list $cb [list InfoBestMove [list $best]]]
}

# --------------------------------------------------------------------- run --
proc runScenario {label {prefilled {}}} {
    array unset ::CMT ; array set ::CMT {}
    array unset ::NG ; array set ::NG {}
    set ::ENGINE_LOG {}
    set ::done 0
    ::cr_settings::pickDefaults
    set ::cr_settings::s(depth) 12
    set ::cr_settings::s(engine_analysis) "Stockfish 19"
    set ::cr_settings::s(engine_verify) "Berserk 14"
    set ::cr_settings::s(verify_mode) candidates
    set ::cr_settings::s(api_key) ""
    ::cr_review::buildLine $::G(mainLine)
    ::cr_review::launch $prefilled
    # a run that needs no engine finishes synchronously; do not wait for a
    # done flag that is already set
    if {!$::done} { vwait ::done }
    puts "scenario: $label  log=[llength $::ENGINE_LOG] lines"
}

# --------------------------------------------------------------- assertions --
set fails 0
proc check {label cond detail} {
    if {$cond} {
        puts "  ok   $label"
    } else {
        incr ::fails
        puts "  FAIL $label -- $detail"
    }
}

runScenario "blunder"

puts "\n== pipeline =="
set mv $::cr_review::R(movesOut)
check "16 plies analysed" [expr {[llength $mv] == 16}] "got [llength $mv]"
set labels [lmap m $mv {dict get $m classification}]
puts "  labels: $labels"
check "opening plies are book" [expr {[lindex $labels 0] eq "book" && [lindex $labels 11] eq "book"}] "got [lindex $labels 0]/[lindex $labels 11]"
check "ply 13 is a blunder" [expr {[lindex $labels 12] eq "blunder"}] "got [lindex $labels 12]"
check "ply 14 is not a blunder" [expr {[lindex $labels 13] ne "blunder"}] "got [lindex $labels 13]"

puts "\n== writeback =="
check "NAG ?? on ply 13" [expr {[info exists ::NG(13)] && [lsearch $::NG(13) "??"] >= 0}] "got [expr {[info exists ::NG(13)] ? $::NG(13) : "none"}]"
set c13 [expr {[info exists ::CMT(13)] ? $::CMT(13) : ""}]
check "comment starts with \[Blunder\]" [string match {\[Blunder\]*} $c13] "got '$c13'"
check "comment carries eval token" [string match {*%eval*} $c13] "got '$c13'"
check "no comment on book move" [expr {![info exists ::CMT(3)] || [string first "\[Book\]" $::CMT(3)] < 0}] "ply 3 = '[expr {[info exists ::CMT(3)] ? $::CMT(3) : ""}]'"
set hdr [expr {[info exists ::CMT(0)] ? $::CMT(0) : ""}]
check "header has accuracy" [string match {*\[Game review\]*Accuracy*} $hdr] "got '$hdr'"

puts "\n== report =="
set rep [::cr_review::reportText]
puts $rep
check "report mentions Est. Elo" [string match {*Est. Elo*} $rep] "no Elo line"
check "report lists key moments" [string match {*Key moments*} $rep] "no key moments"

puts "\n== verifier scenario =="
set ::EVAL {-20 -20 -20 -20 -20 -20 -20 -20 -20 -20 -20 -20 30 30 30 30 30}
set ::GAP 250
set ::FORCE_NOTBEST 0
runScenario "great + verifier disagrees"
set mv2 $::cr_review::R(movesOut)
set labels2 [lmap m $mv2 {dict get $m classification}]
puts "  labels: $labels2"
check "ply 13 was upgraded to great then withdrawn" [expr {[lindex $labels2 12] eq "best"}] "got [lindex $labels2 12]"
check "second engine was used" [expr {[lsearch -regexp $::ENGINE_LOG {^21 Go}] >= 0}] "log: $::ENGINE_LOG"

puts "\n== eco book boundary =="
set ::BOOKEND 6
set ::EVAL {-20 -20 -20 -20 -20 -20 -20 -20 -20 -20 -20 -20 -20 -20 -20 -20 -20}
set ::GAP 30
set ::FORCE_NOTBEST 0
runScenario "eco book ends at ply 6"
set labels3 [lmap m $::cr_review::R(movesOut) {dict get $m classification}]
puts "  labels: $labels3  (bookEnd=$::cr_review::R(bookEnd))"
check "book stops at the ECO ply" [expr {[lindex $labels3 5] eq "book" && [lindex $labels3 6] ne "book"}] "got [lindex $labels3 5]/[lindex $labels3 6]"

puts "\n== llm payload =="
set body [::cr_llm::body "hello \"world\"\nline2"]
check "model json starts with the model field" [expr {[string first {"model":} $body] == 1}] "got $body"
set parsed [::cr_llm::extractContent {"message":{"role":"assistant","content":"A pawn is loose on c3."},"done":true}]
check "content extraction" [expr {$parsed eq "A pawn is loose on c3."}] "got '$parsed'"
set esc [::cr_llm::extractContent {"content":"say \"hi\"\nthen stop"}]
check "escape handling" [expr {$esc eq "say \"hi\"\nthen stop"}] "got '$esc'"

puts "\n== engine calls =="
puts "  [join $::ENGINE_LOG \n  ]"
puts "\n== cloud-prefilled pipeline =="
# Same game, but every searched position arrives from the cloud: the engine
# must not run, and the labels must come out identical to the local pass.
set ::EVAL {-20 -20 -20 -20 -20 -20 -20 -20 -20 -20 -20 -20 30 -300 -300 -280 -290}
set ::BOOKEND 12
set ::GAP 30
set ::FORCE_NOTBEST 1
set cloud {}
foreach {idx} {12 13 14 15 16} {
    set whiteCp [lindex $::EVAL $idx]
    set stm [expr {$idx % 2 == 0 ? "w" : "b"}]
    set cp [expr {$stm eq "w" ? $whiteCp : -$whiteCp}]
    set pv1 "e2e4 e7e5 g1f3"
    set pv2 "d2d4 d7d5 c2c4"
    set pv3 "c2c4 g8f6 d2d4"
    set one [dict create 1 [list $cp cp $pv1 55] 2 [list [expr {$cp-30}] cp $pv2 55] 3 [list [expr {$cp-60}] cp $pv3 55]]
    dict set cloud $idx $one
}
runScenario "cloud prefilled" $cloud
set mvC $::cr_review::R(movesOut)
set labelsC [lmap m $mvC {dict get $m classification}]
puts "  labels: $labelsC"
check "cloud run labels 13 a blunder" [expr {[lindex $labelsC 12] eq "blunder"}] "got [lindex $labelsC 12]"
check "cloud run did not start the analysis engine" [expr {[lsearch -regexp $::ENGINE_LOG {^20 Go}] < 0}] "log: $::ENGINE_LOG"
check "cloud run still wrote the comment" [string match {\[Blunder\]*} [expr {[info exists ::CMT(13)] ? $::CMT(13) : ""}]] "got '[expr {[info exists ::CMT(13)] ? $::CMT(13) : ""}]'"

puts "\n== phase prose lands at the end of its phase =="
# The coach finished: a summary and two phase paragraphs are waiting to be
# written. Phase blocks must go to the last ply of their own phase, and the
# header must keep the game review without repeating them.
set ::CMT(10) {[Inaccuracy] 13...Bxe4 was better [%eval +0.44]}
set ::CMT(16) {[Best] [%eval +2.10]}
set ::cr_review::R(phaseStats) [dict create \
    opening [dict create from_ply 1 to_ply 10 plies 10 accuracy_white 82.1 accuracy_black 64.4 acpl_white 18 acpl_black 45] \
    middlegame [dict create from_ply 11 to_ply 16 plies 6 accuracy_white 55.0 accuracy_black 40.2 acpl_white 60 acpl_black 90] \
    endgame ""]
array set ::cr_llm::J {game 1 done 0 total 3}
set ::cr_llm::J(texts) [dict create]
dict set ::cr_llm::J(texts) [list phase opening] "The opening began level and stayed level."
dict set ::cr_llm::J(texts) [list phase middlegame] "White converted the phase after the rook trade."
dict set ::cr_llm::J(texts) [list summary 0] "SUMMARY: The game turned on move 21, when a rook was won.\nLEVEL: Both sides played at club level; Black should have checked whether the piece was defended.\nOPENING: NONE"
::cr_llm::applyProse
set c10 $::CMT(10)
set c16 $::CMT(16)
set c0 $::CMT(0)
check "phase block on the last opening ply" [string match {*\[Phase opening\]*} $c10] "got '$c10'"
check "phase block carries its figures" [string match {*plies 1-10*} $c10] "got '$c10'"
check "phase block keeps the move comment" [string match {*\[Inaccuracy\]*} $c10] "got '$c10'"
check "second phase on its own last ply" [string match {*\[Phase middlegame\]*} $c16] "got '$c16'"
check "header keeps the summary" [string match {*The game turned on move 21*} $c0] "got '$c0'"
check "header no longer repeats the phases" [expr {![string match {*Phase review*} $c0] && ![string match {*\[Phase*} $c0]}] "got '$c0'"
set stripped [::cr_review::stripOurLabels $c10]
check "a re-review strips the phase block" [expr {![string match {*\[Phase*} $stripped]}] "got '$stripped'"
check "stripping also removes the label and the eval" [expr {![string match {*Inaccuracy*} $stripped] && ![string match {*%eval*} $stripped]}] "got '$stripped'"
check "header line survived stripping" [expr {[string trim $stripped] eq ""}] "got '$stripped'"

puts "\n== level line does not ask for a habit =="
set sp [::cr_llm::summaryPrompt]
check "no 'single habit' instruction" [expr {[string first "single habit" $sp] < 0}] "prompt still asks for a habit"
check "states that one game cannot show a habit" [expr {[string first "cannot show a habit" $sp] >= 0}] "no ban on the word"
check "asks for an improvement in this game" [expr {[string first "in THIS game" $sp] >= 0}] "no single-game framing"
check "tells the model to use the net material" [expr {[string first "net material after the punishment" $sp] >= 0}] "no net material rule"

puts "\n== the window opens before the new work =="
set ::SEQ {}
rename ::cr_review::log ::cr_review::logOrig
proc ::cr_review::log {msg} { lappend ::SEQ "log:$msg" ; catch { ::cr_review::logOrig $msg } }
proc ::cr_ui::progressOpen {args} { lappend ::SEQ "progressOpen [lindex $args 1]" }
proc ::cr_ui::progressStage {args} { lappend ::SEQ "stage:[lindex $args 0]" }
set ::LAST_SET ""
proc ::cr_ui::progressSet {done total msg} { set ::LAST_SET "$msg $done/$total" }
set ::cr_settings::s(cloud_mode) off
set ::cr_settings::s(book_mode) eco
array unset ::cr_review::R ; array set ::cr_review::R {}
set ::done 0
::cr_review::start
if {!$::done} { vwait ::done }
puts "  sequence: $::SEQ"
set iOpen [lsearch -regexp $::SEQ {^progressOpen}]
set iBook [lsearch -regexp $::SEQ {^log:book}]
check "progress window exists" [expr {$iOpen >= 0}] "seq: $::SEQ"
check "window opens before the book probe" [expr {$iOpen < $iBook}] "open=$iOpen book=$iBook"
check "window opens before the engine starts" [expr {$iOpen < [lsearch -regexp $::SEQ {^log:launch}]}] "seq: $::SEQ"
check "book probe runs with the window up" [expr {[lsearch -regexp $::SEQ {^log:book: }] > [lsearch -regexp $::SEQ {^progressOpen}]}] "seq: $::SEQ"
check "analysis gets its own stage" [expr {[lsearch -regexp $::SEQ {^stage:Analysing}] > 0}] "seq: $::SEQ"
::cr_review::onCloudProgress 3 28 9
check "cloud progress shows the usable count" [expr {[string first "9 usable" $::LAST_SET] >= 0 && [string first "3/28" $::LAST_SET] >= 0}] "got '$::LAST_SET'"

puts "\n== a phase with no prose still gets its block =="
array set ::CMT {}
set ::cr_review::R(phaseStats) [dict create \
    opening [dict create from_ply 1 to_ply 10 plies 10 accuracy_white 70.0 accuracy_black 60.0 acpl_white 20 acpl_black 30] \
    middlegame "" \
    endgame [dict create from_ply 11 to_ply 16 plies 6 accuracy_white 55.0 accuracy_black 44.0 acpl_white 50 acpl_black 70]]
array set ::cr_llm::J {game 1 done 0 total 1}
set ::cr_llm::J(texts) [dict create]
dict set ::cr_llm::J(texts) [list phase opening] "The opening was quiet."
::cr_llm::applyProse
check "opening block written" [string match {*\[Phase opening\]*} $::CMT(10)] "got '$::CMT(10)'"
check "endgame block written without prose" [string match {*\[Phase endgame\]*} $::CMT(16)] "got '$::CMT(16)'"
check "endgame block carries its figures" [string match {*accuracy W 55.0%*} $::CMT(16)] "got '$::CMT(16)'"

puts "\n== phase prompt asks for consequences =="
set pp [::cr_llm::phasePrompt opening]
check "does not ask for a move-by-move grouping" [expr {[string first "group by side" $pp] < 0}] "prompt still groups by side"
check "forbids going through the moves in order" [expr {[string first "Never go through the moves in game order" $pp] >= 0}] "no anti-list rule"

puts "\nfailures: $::fails"
exit [expr {$::fails ? 1 : 0}]
