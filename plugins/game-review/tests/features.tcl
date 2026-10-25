# h_features.tcl -- unit tests for the six grafts (book probe, cloud pre-pass,
# prose normaliser, model list, ECO name, tree line). Runs in tclsh with stubs.

set ::scidUserDir /tmp/crtest
file mkdir /tmp/crtest/plugins

if {[llength [info commands winfo]] == 0} { proc winfo {args} { return 0 } }
if {[llength [info commands menu]] == 0} { proc menu {args} { return "" } }
if {[llength [info commands destroy]] == 0} { proc destroy {args} { return "" } }

set D [file dirname [info script]]
source [file join $D 10_cr_board.tcl]
source [file join $D 11_cr_classify.tcl]
source [file join $D 12_cr_settings.tcl]
source [file join $D 13_cr_engine.tcl]
source [file join $D 14_cr_review.tcl]
source [file join $D 15_cr_llm.tcl]
source [file join $D 16_cr_ui.tcl]
source [file join $D 17_cr_facts.tcl]

namespace eval ::enginecfg {}
proc ::enginecfg::names {} { return {Stockfish 19 Berserk 14} }
namespace eval ::engineNoWin {}
namespace eval ::engine {}
namespace eval ::cr_ui_log {}
proc ::cr_ui::log {msg} { catch { lappend ::UI_LOG $msg } }
proc ::cr_review::log {msg} { catch { lappend ::REV_LOG $msg } }

set fails 0
proc check {label cond detail} {
    if {$cond} { puts "  ok   $label" } else { incr ::fails ; puts "  FAIL $label -- $detail" }
}
proc chkeq {label got want} {
    check $label [expr {$got eq $want}] "got '$got' want '$want'"
}

# ---------------------------------------------------------------- #4 sanFix --
puts "\n== #4 prose normaliser =="
chkeq "lowercase piece move" [::cr_llm::sanFix "the knight goes nf3 now"] {the knight goes Nf3 now}
chkeq "lowercase capture" [::cr_llm::sanFix "and nxf3 wins"] {and Nxf3 wins}
chkeq "capitalised pawn move" [::cr_llm::sanFix "the push A6 is slow"] {the push a6 is slow}
chkeq "markdown bold stripped" [::cr_llm::sanFix "this is **bad** play"] {this is bad play}
chkeq "words are left alone" [::cr_llm::sanFix "black knight keeps the king safe"] {black knight keeps the king safe}
chkeq "proper SAN untouched" [::cr_llm::sanFix "Nf3 and Bb5+ then O-O"] {Nf3 and Bb5+ then O-O}
set prose [::cr_llm::cleanProse "White plays nf3 \u2014 a quiet move"]
set nonascii [regexp {[^\x01-\x7e]} $prose]
check "cleanProse maps typography" [expr {$nonascii == 0}] "got '$prose'"

# ---------------------------------------------------------------- #5 listModels --
puts "\n== #5 model list parsing =="
set raw {"object":"list","data":[{"id":"qwen3-embedding:0.6b"},{"id":"deepseek-v4-pro:1017"}]}
set ids {}
foreach {all id} [regexp -all -inline {"id"\s*:\s*"([^"]+)"} $raw] { lappend ids $id }
check "openai-shaped list parsed" [expr {[llength $ids] == 2 && [lindex $ids 0] eq "qwen3-embedding:0.6b"}] "got $ids"
set raw2 {"models":[{"name":"gemma4:31b"},{"name":"qwen3:0.6b"}]}
set ids2 {}
foreach {all nm} [regexp -all -inline {"name"\s*:\s*"([^"]+)"} $raw2] { lappend ids2 $nm }
check "ollama tags parsed" [expr {[llength $ids2] == 2 && [lindex $ids2 1] eq "qwen3:0.6b"}] "got $ids2"

# ---------------------------------------------------------------- #6 ecoName --
puts "\n== #6 ECO name =="
proc sc_eco {args} {
    if {[lindex $args 0] eq "summary"} {
        return "C60 \[Ruy Lopez\]  1. e4 e5 2. Nf3 Nc6 3. Bb5"
    }
    return ""
}
chkeq "name from the ECO table" [::crfacts::ecoName C60] {Ruy Lopez}
proc sc_eco_empty {args} { return "" }
rename sc_eco ::sc_eco_real
proc sc_eco {args} { return "" }
chkeq "unknown code gives no name" [::crfacts::ecoName Z99] ""
rename sc_eco {}
rename ::sc_eco_real sc_eco

# ---------------------------------------------------------------- #1 book probe --
puts "\n== #1 book probe =="
array unset ::cr_review::R
array set ::cr_review::R {}
set ::cr_review::R(n) 3
set ::cr_review::R(moves) {e2e4 e7e5 g1f3}
set ::cr_settings::s(book_mode) book
set ::cr_settings::s(book_file) /tmp/crtest/book.bin
set fh [open /tmp/crtest/book.bin w] ; puts $fh dummy ; close $fh
set ::BOOKPOS 0
set ::BOOKSEQ [list {e4 40% d4 30%} {e5 60% c5 40%} {c5 20%}]
set ::G(ply) 0
set ::SANS {e4 e5 Nf3}
set ::PLAYED_SAN ""
proc sc_book {args} {
    switch -- [lindex $args 0] {
        load  { return "" }
        moves { set v [lindex $::BOOKSEQ $::BOOKPOS] ; incr ::BOOKPOS ; return [list $v ""] }
        close { return "" }
    }
    return ""
}
namespace eval ::uci {}
proc ::uci::sc_move_add {moves} {
    incr ::G(ply)
    set ::PLAYED_SAN [lindex $::SANS [expr {$::G(ply) - 1}]]
    return 0
}
proc sc_game {args} {
    switch -- [lindex $args 0] {
        push { set ::G(pushply) $::G(ply) ; return "" }
        pop  { set ::G(ply) [expr {[info exists ::G(pushply)] ? $::G(pushply) : 0}] ; return "" }
        info { if {[lindex $args 1] eq "previousMoveNT"} { return $::PLAYED_SAN } ; return "" }
    }
    return ""
}
set flags [::cr_review::bookFlags]
check "book flags from the played moves" [expr {$flags eq {1 1 0}}] "got '$flags'"
# the probe is stateless in the real code; reset the stub's book cursor and let
# bookInfo run it once and cache the verdict
set ::BOOKPOS 0 ; set ::G(ply) 0
array unset ::cr_review::R ; array set ::cr_review::R {}
set ::cr_review::R(n) 3
set ::cr_review::R(moves) {e2e4 e7e5 g1f3}
set info [::cr_review::bookInfo]
check "book flags cached in bookInfo" [expr {[dict get $info flags] eq {1 1 0}}] "got $info"
check "book info start index" [expr {[dict get $info start] == 2}] "got $info"
check "book source is the book" [expr {[dict get $info source] eq "book"}] "got $info"

# a book that does not contain the game at all -> fall back to the ECO probe
array unset ::cr_review::R ; array set ::cr_review::R {}
set ::cr_review::R(n) 2
set ::cr_review::R(moves) {e2e4 e7e5}
set ::BOOKPOS 0
set ::BOOKSEQ [list {} {}]
set ::G(ply) 0
set ::SANS {e4 e5}
proc sc_game {args} {
    switch -- [lindex $args 0] {
        push { set ::G(pushply) $::G(ply) ; return "" }
        pop  { return "" }
        info { return $::PLAYED_SAN }
        eco  { return 0 }
    }
    return ""
}
set f2 [::cr_review::bookFlags]
check "no book hit -> empty flags" [expr {[llength $f2] == 2 && [lindex $f2 0] == 0}] "got '$f2'"

# ---------------------------------------------------------------- #2 cloud parse --
puts "\n== #2 cloud pre-pass =="
set js {{"fen":"x","knodes":5,"depth":42,"pvs":[{"moves":"e2e4 e7e5 g1f3","cp":-35},{"moves":"d2d4 d7d5","cp":-90}]}}
set dW [::cr_engine::cloudParse $js "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"]
lassign [dict get $dW 1] s1 t1 p1 dp1
check "white-to-move keeps the sign" [expr {$s1 == -35 && $t1 eq "cp" && $dp1 == 42}] "got [dict get $dW 1]"
set dB [::cr_engine::cloudParse $js "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1"]
lassign [dict get $dB 1] s2 t2 p2 dp2
check "black-to-move flips the sign" [expr {$s2 == 35}] "got [dict get $dB 1]"
check "two PV lines kept" [expr {[dict size $dB] == 2}] "got [dict size $dB]"
set jsM {{"depth":30,"pvs":[{"moves":"e2e4","mate":3}]}}
lassign [dict get [::cr_engine::cloudParse $jsM "8/8/8/8/8/8/8/K6k w - - 0 1"] 1] sm tm
check "mate score carried as mate" [expr {$tm eq "mate" && $sm == 3}] "got $tm/$sm"
check "error body -> no evals" [expr {[::cr_engine::cloudParse {"error":"Not found"} "8/8/8/8/8/8/8/K6k w - - 0 1"] eq ""}] "parse accepted an error body"

# uniform policy: partial coverage must fall back to a full local pass
array unset ::cr_engine::CLOUD
array set ::cr_engine::CLOUD {queue {} q 0 total 4 prefilled {} accepted 3 misses 1 consec 0 aborted 0 mode uniform minDepth 18 minPv 3 fens {} onProgress {} onDone ::cloud_done}
set ::GOT ""
proc ::cloud_done {prefilled stats} { set ::GOT [list $prefilled $stats] }
::cr_engine::cloudFinish
check "uniform partial -> no prefilled" [expr {[dict get [lindex $::GOT 0] ] eq "" || [dict size [lindex $::GOT 0]] == 0}] "got '[lindex $::GOT 0]'"
check "uniform partial reported" [expr {[dict get [lindex $::GOT 1] accepted] == 3}] "got [lindex $::GOT 1]"
array set ::cr_engine::CLOUD {queue {} q 0 total 4 prefilled {} accepted 4 misses 0 consec 0 aborted 0 mode uniform minDepth 18 minPv 3 fens {} onProgress {} onDone ::cloud_done}
dict set ::cr_engine::CLOUD(prefilled) 1 {1 {10 cp {e2e4} 20}}
::cr_engine::cloudFinish
check "uniform complete keeps prefilled" [expr {[dict size [lindex $::GOT 0]] == 1}] "got [lindex $::GOT 0]"

# prefilled positions must never reach the engine
set ::SENT {}
proc ::engineNoWin::initEngine {id engine cb} { set ::CB($id) $cb ; return 1 }
proc ::engineNoWin::closeEngine {id} { return "" }
proc ::engine::send {id msg data} { lappend ::SENT [list $id $msg $data] ; return "" }
set ::cr_settings::s(depth) 12
set ::cr_settings::s(engine_analysis) "Stockfish 19"
::cr_engine::run [dict create positions {p0 p1 p2 p3} startIndex 0 depth 12 engine1 "Stockfish 19" \
    prefilled [dict create 1 {1 {10 cp {e2e4} 20}} 2 {1 {20 cp {d2d4} 20}}] \
    onStatus "" onDone "" onError ""]
set sentGo [lmap e $::SENT { if {[lindex $e 1] eq "Go"} { lindex [lindex $e 2] 0 } }]
set sentGo [lsearch -all -inline -not -exact $sentGo ""]
check "first search is the first gap" [expr {[llength $sentGo] == 1 && [lindex $sentGo 0] eq "p0"}] "sent: $sentGo"
check "prefilled positions never reach the engine" [expr {[lsearch -regexp $sentGo {p1|p2}] < 0}] "sent: $sentGo"
set ev [::cr_engine::evals]
check "prefilled evals are in the results" [expr {[dict exists $ev 1] && [dict exists $ev 2]}] "got $ev"

# #7 tree line parsing
puts "\n== #7 tree line =="
proc sc_base {args} { if {[lindex $args 0] eq "numGames"} { return 4200 } ; return 0 }
proc sc_filter {args} { return "" }
proc sc_tree {args} { return "Move(s)  ECO   Games: Score AvElo Perf AvLen AvYear %Draws %Win\n  1: e4 e5 Nf3 Nc6  A00  1204: 45.6% 52.3% 2100 2200 45 1995 32% 48.25%\nTOTAL: 999" }
set tl [::crfacts::treeLine]
check "tree line parses games and score" [string match {*1204 games*} $tl] "got '$tl'"
check "tree line names the score" [string match {*45.6%*} $tl] "got '$tl'"
proc sc_base {args} { if {[lindex $args 0] eq "numGames"} { return 5000000 } ; return 0 }
check "large base is skipped" [expr {[::crfacts::treeLine] eq ""}] "got '[::crfacts::treeLine]'"

# ---------------------------------------------------------------- phase split --
puts "\n== phase split is book-independent =="
# Six opening-like plies, then a sparse board: openingOver fires at ply 7.
set openFen "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
set sparseFen "r2q1rk1/pp2ppbp/2n2n2/8/8/2N2N2/PP1QBPPP/R4RK1 w - - 0 20"
set recs {}
for {set i 1} {$i <= 6} {incr i} {
    lappend recs [dict create ply $i side [expr {$i % 2 ? "white" : "black"}] \
        fen_after $openFen eval_after_cp 10 player_before 10 player_after 10 \
        classification best]
}
for {set i 7} {$i <= 12} {incr i} {
    lappend recs [dict create ply $i side [expr {$i % 2 ? "white" : "black"}] \
        fen_after $sparseFen eval_after_cp 10 player_before 10 player_after 10 \
        classification best]
}
set ps [::crclass::phaseSplit $recs]
set mid7 [dict get [dict get $ps middlegame] from_ply]
check "opening ends at the first non-opening position" [expr {$mid7 == 7}] "got $mid7"
set ps2 [::crclass::phaseSplit $recs 40]
check "a book boundary argument changes nothing" [expr {[dict get [dict get $ps2 middlegame] from_ply] == $mid7}] "got [dict get [dict get $ps2 middlegame] from_ply]"
check "opening phase covers plies 1-6" [expr {[dict get [dict get $ps opening] from_ply] == 1 && [dict get [dict get $ps opening] to_ply] == 6}] "got [dict get $ps opening]"

# ------------------------------------------------------- phase block format --
puts "\n== phase block =="
set st [dict create from_ply 11 to_ply 31 plies 21 accuracy_white 82.1 accuracy_black 64.4 acpl_white 18 acpl_black 45]
set blk [::cr_llm::phaseBlock middlegame $st "The middlegame began level."]
check "block opens with the marker" [expr {[string first "\[Phase middlegame\]" $blk] == 0}] "got '$blk'"
check "block carries plies and figures" [expr {[string first "plies 11-31 - accuracy W 82.1% B 64.4%, acpl (average centipawn loss) W 18 B 45." $blk] >= 0}] "got '$blk'"
check "prose follows on its own line" [expr {[string first "\nThe middlegame began level." $blk] >= 0}] "got '$blk'"
set bad [regexp {[^\x01-\x7e\n]} $blk]
check "block is ascii" [expr {$bad == 0}] "got '$blk'"

# --------------------------------------------------- scores: mate vs tablebase --
puts "\n== mate and tablebase scores =="
set mateFmt [::cr_review::fmtEval [::cr_review::evalToCp 3 mate]]
check "mate renders as scid's #N token" [expr {$mateFmt eq "#3"}] "got '$mateFmt'"
set negMate [::cr_review::fmtEval [::cr_review::evalToCp -2 mate]]
check "negative mate renders #-N" [expr {$negMate eq "#-2"}] "got '$negMate'"
set tb [::cr_review::fmtEval 9165]
check "a tablebase score clamps instead of printing +91.65" [expr {$tb eq "+20.00"}] "got '$tb'"
set normal [::cr_review::fmtEval 995]
check "an ordinary score is unchanged" [expr {$normal eq "+9.95"}] "got '$normal'"
check "tablebase range is not a mate" [expr {![::crclass::isMateCp 9165]}] "9165 treated as mate"
check "mate sentinel is a mate" [expr {[::crclass::isMateCp [::crclass::mateToCp 4]]}] "mateToCp not recognised"

# ------------------------------------------------------- great in a lost game --
puts "\n== a forced move in a lost position is not great =="
set args {-base best -isBest 1 -cpLoss 5 -fenBefore "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"     -fenAfter "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"     -sideToMove w -playerEvalBeforeCp -363 -playerEvalAfterCp -392 -ply 40     -legalMoveCount 4 -candidatePlayerCps {0 -250} -pvAfterPlayed {} -inBook "" -playedUci e2e4 -winDrop 1}
set clsLost [::crclass::refineClassification {*}$args]
check "no great when the mover is already lost" [expr {$clsLost ne "great"}] "got '$clsLost'"
set args2 [string map {-playerEvalBeforeCp\ -363\ -playerEvalAfterCp\ -392 -playerEvalBeforeCp\ 30\ -playerEvalAfterCp\ 30} $args]
set clsOk [::crclass::refineClassification {*}$args2]
check "still great while the game is in doubt" [expr {$clsOk eq "great"}] "got '$clsOk'"

# --------------------------------------------------------- fork and net material --
puts "\n== punishment facts =="
set fenA "r4rk1/pb5p/2n1R1p1/2pp4/6N1/2PB4/PP3PPP/2R3K1 b - - 0 21"
set fenB "4k3/pb5p/2n3p1/2pp4/8/2PB4/PP3PPP/2R3K1 w - - 0 25"
set fenFork "4r1k1/pb5p/2n3p1/2pp4/6N1/2PB4/PP3PPP/2R3K1 w - - 0 23"
set sw [::crfacts::materialSwing $fenA $fenB]
check "net material names the exchange" [expr {[string first "White won the exchange (a rook for a knight)" $sw] >= 0}] "got '$sw'"
set fk [::crfacts::forkLine $fenFork g4f6]
check "the fork is recognised" [expr {[string first "fork" $fk] >= 0 && [string first "rook on e8" $fk] >= 0}] "got '$fk'"
check "a rook move is not a fork" [expr {[::crfacts::forkLine $fenA a8e8] eq ""}] "got '[::crfacts::forkLine $fenA a8e8]'"

# --------------------------------------------- better-move reasons are not invented --
puts "\n== the better-move facts do not invite invention =="
# after 3...Bg4: Nc6 and Nd7 both develop, so a fact that credits only Nc6 with
# developing invites "failed to develop as Nc6 would have".
set fenD2 "rn2kbnr/ppp1pppp/8/3q4/6b1/5N2/PPPPBPPP/RNBQK2R b KQkq - 3 4"
set gNc6 [::crfacts::gainsOf $fenD2 b8c6 b]
set gNd7 [::crfacts::gainsOf $fenD2 b8d7 b]
check "Nc6 develops" [expr {[lsearch -exact $gNc6 "develops a piece"] >= 0}] "got '$gNc6'"
check "Nd7 develops too" [expr {[lsearch -exact $gNd7 "develops a piece"] >= 0}] "got '$gNd7'"

puts "\n== a mating move is not a level position =="
check "checkmate detected" [expr {[::crclass::isMatePosition "R5k1/5ppp/8/8/8/8/5PPP/6K1 b - - 0 1"] == 1}] "mate FEN not recognised"
check "stalemate is not mate" [expr {[::crclass::isMatePosition "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1"] == 0}] "stalemate treated as mate"
check "ordinary position is not mate" [expr {[::crclass::isMatePosition "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"] == 0}] "start position treated as mate"
set mateCp [::crclass::mateToCp 0]
check "a mating move formats as #1" [expr {[::cr_review::fmtEval $mateCp] eq "#1"}] "got '[::cr_review::fmtEval $mateCp]'"

puts "\nfailures: $::fails"
exit [expr {$::fails ? 1 : 0}]
