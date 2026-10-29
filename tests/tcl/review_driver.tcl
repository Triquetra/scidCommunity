#!/usr/bin/env tclsh
# The engine pass behind Game Review / Move Comment, driven by a stub engine.

set fails 0
set checks 0

proc check {name cond} {
    global fails checks
    incr checks
    if {![uplevel 1 [list expr $cond]]} {
        incr fails
        puts "FAIL $name"
    }
}

proc checkEq {name got want} {
    global fails checks
    incr checks
    if {$got ne $want} {
        incr fails
        puts "FAIL $name -- got '$got' want '$want'"
    }
}

set root [file normalize [file join [file dirname [info script]] .. ..]]
source [file join $root tcl tools accuracy.tcl]
source [file join $root tcl tools move_labels.tcl]
source [file join $root tcl enginecfg.tcl]
source [file join $root tcl tools engine_limits.tcl]
source [file join $root tcl tools game_review.tcl]
source [file join $root tcl tools review_driver.tcl]

# The engine layer, stubbed: the driver's job is which messages it sends and
# what it does with the replies, not how a pipe to Stockfish works. The stub keeps
# ::engine::connect's own parameter list and records the argv that list would build,
# because whether "uci" is the protocol or the engine's first argument is decided
# there.
set ::sent {}
set ::closed {}
set ::argv_seen {}
set ::connseq 0
namespace eval ::engine {}
proc ::engine::setLogCmd {id args} {}
proc ::engine::connect {id callback exe args {protocols {uci xboard}}} {
    incr ::connseq
    set ::engconn(channel_$id) chan$::connseq
    set ::engconn(callback_$id) $callback
    set ::engine_callback $callback
    lappend ::sent [list connect $id $exe $args $protocols]
    # What the real connect hands the OS: the engine, then the args list.
    lappend ::argv_seen [concat [list $exe] $args]
}
proc ::engine::send {id msg args} {
    lappend ::sent [list send $id $msg [lindex $args 0]]
}
proc ::engine::close {id} {
    unset -nocomplain ::engconn(channel_$id)
    unset -nocomplain ::engconn(callback_$id)
    lappend ::closed $id
}

proc feed {msgType msgData} {
    {*}$::engine_callback [list $msgType $msgData]
}

# The driver queues its close instead of closing inside the engine's reply (a close
# there unset the arrays ::engine::reply walks next), so a test that wants to see the
# close has to run the event loop.
proc pump {} {
    after idle {set ::pumped 1}
    vwait ::pumped
    unset -nocomplain ::pumped
}

set enginecfg {Stockfish /usr/bin/stockfish {} {} 0 0 {} 1 {
    {Threads 8 integer 1 1 128}
    {Hash 256 spin 16 1 4096}
    {MultiPV 1 spin 1 1 10}
}}

puts "what a pass runs with"
::review::reset
checkEq "threads come from the engine's config" [dict get [::review::effective $enginecfg] threads] 8
checkEq "and so does hash" [dict get [::review::effective $enginecfg] hash] 256
checkEq "a review always asks for two lines" [dict get [::review::effective $enginecfg] mpv] 3
::review::setValue threads 2
checkEq "the preset still wins over a ::review value" \
    [dict get [::review::effective $enginecfg] threads] 8
::review::setValue mpv 1
checkEq "one line is raised to two" [dict get [::review::effective $enginecfg] mpv] 2
set wide {Stockfish /usr/bin/stockfish {} {} 0 0 {} 1 {{MultiPV 5 spin 1 1 10}}}
checkEq "a preset asking for more lines is respected" \
    [dict get [::review::effective $wide] mpv] 5
::review::reset
::review::setValue threads 4
::review::setValue hash_mb 64
checkEq "an engine that advertises nothing leaves them unset" \
    [dict get [::review::engineDefaults {X /x {} {} 0 0 {} 1 {}}] threads] {}
checkEq "and a pass cannot borrow ::review's threads for it" \
    [dict get [::review::effective {X /x {} {} 0 0 {} 1 {}}] threads] {}
checkEq "nor its hash" \
    [dict get [::review::effective {X /x {} {} 0 0 {} 1 {}}] hash] {}
::review::reset

puts "where the depth comes from"
set ::engines(list) [list \
    [list Plain /x {} {} 0 0 {} 1 {} {}] \
    [list Deep /x {} {} 0 0 {} 1 {} [dict create depth 30]] \
    [list Shallow /x {} {} 0 0 {} 1 {} [dict create depth 12]]]
::review::reset
checkEq "a preset with no limits leaves the review depth alone" \
    [dict get [::review::effective [::enginecfg::get Plain]] depth] 18
checkEq "a deeper preset raises it" \
    [dict get [::review::effective [::enginecfg::get Deep]] depth] 30
checkEq "a shallower preset does not lower it" \
    [dict get [::review::effective [::enginecfg::get Shallow]] depth] 18

puts "a pass over three positions"
set ::progress {}
set ::done ""
proc onProgress {n total ply lines} { lappend ::progress [list $n $total $ply] }
proc onDone {results} { set ::done $results }
set positions {{4 {fen A}} {5 {fen B}} {6 {fen C}}}
set token [::reviewdriver::start $enginecfg $positions 3 18 ::onProgress ::onDone]
checkEq "the engine was opened on the pass's own id" [lindex $::sent 0] {connect 20 /usr/bin/stockfish {} uci}
checkEq "with uci as the protocol, never as the engine's argument" \
    [lindex $::argv_seen 0] {/usr/bin/stockfish}
feed InfoConfig {Threads 8 Hash 256 MultiPV 3}
set opt [lsearch -inline $::sent {send 20 SetOptions*}]
check "the pass asks for its own MultiPV" [string match {*MultiPV 3*} $opt]
check "and passes the engine's threads" [string match {*Threads 8*} $opt]
checkEq "the first position is searched at the review depth" [lindex $::sent end] {send 20 Go {{fen A} {depth 18}}}

feed InfoPV {1 10 12 500 200 0 0 90 cp 0 e2e4 e7e5}
feed InfoPV {1 12 15 900 300 0 0 120 cp 0 d2d4 d7d5}
# A shallower line for the same slot must not overwrite the deeper one: an
# engine can report depths out of order between PV updates.
feed InfoPV {1 9 9 100 50 0 0 30 cp 0 d2d4 d7d5}
feed InfoPV {2 8 9 300 100 0 0 60 cp 0 c2c4 c7c5}
feed InfoBestMove {}
checkEq "progress reports the position just finished" [lindex $::progress 0] {1 3 4}
checkEq "the next position is searched" [lindex $::sent end] {send 20 Go {{fen B} {depth 18}}}

feed InfoPV {1 9 10 400 100 0 0 70 cp 0 g1f3 g8f6}
feed InfoBestMove {}
feed InfoPV {1 11 11 500 100 0 0 80 cp 0 b1c3 b8c6}
feed InfoBestMove {}

checkEq "the engine is not closed from inside the last reply" $::closed {}
pump
checkEq "the engine is closed once the reply has returned" $::closed {20}
check "the result carries every ply" [expr {[llength [dict keys $::done]] == 3}]
set first [dict get $::done 4]
checkEq "the deepest line is kept, not the last" [lindex [dict get $first 1] 0] 12
checkEq "and the second MultiPV slot too" [lindex [dict get $first 2] 0] 8
checkEq "positions after the first are recorded" [lindex [dict get [dict get $::done 6] 1] 0] 11

puts "stopping a pass"
set ::sent {}
set ::done ""
set token [::reviewdriver::start $enginecfg {{4 {fen A}} {5 {fen B}}} 3 18 ::onProgress ::onDone]
feed InfoConfig {}
feed InfoPV {1 10 10 0 0 0 0 10 cp 0 e2e4}
set searches [lsearch -all -inline -glob $::sent {send 20 Go*}]
checkEq "stop reports it did something" [::reviewdriver::stop $token] 1
checkEq "no further search is started" [lsearch -all -inline -glob $::sent {send 20 Go*}] $searches
pump
checkEq "the engine is closed" [lindex $::closed end] 20
checkEq "and the pass is forgotten" [::reviewdriver::stop $token] 0

puts "a preset that passes arguments to its engine"
set ::sent {}
set ::argv_seen {}
set ::closed {}
set withargs {Stockfish /usr/bin/stockfish {-t 4 --no-smp} {} 0 0 {} 1 {}}
set code [catch { ::reviewdriver::start $withargs {{4 {fen A}}} 2 18 {} {} } token]
checkEq "the preset's arguments do not overflow the connect call" $code 0
if {$code == 0} {
    checkEq "the preset's arguments reach the engine" \
        [lindex $::argv_seen 0] {/usr/bin/stockfish -t 4 --no-smp}
    checkEq "and uci is still the protocol" [lindex $::sent 0] \
        {connect 20 /usr/bin/stockfish {-t 4 --no-smp} uci}
    ::reviewdriver::stop $token
    pump
}

puts "a pass stopped from its own progress handler"
set ::sent {}
set ::closed {}
set ::stopped ""
proc onProgressStop {n total ply lines} {
    if {$n == 1} {
        set ::stopped [::reviewdriver::stop $::stopToken]
    }
}
set ::stopToken [::reviewdriver::start $enginecfg {{4 {fen A}} {5 {fen B}}} 2 18 ::onProgressStop ::onDone]
feed InfoConfig {}
feed InfoBestMove {}
checkEq "the handler stopped the pass" $::stopped 1
check "and no position after it is started" \
    [expr {[llength [lsearch -all -inline -glob $::sent {send 20 Go*}]] == 1}]
pump
checkEq "the engine is closed once the loop runs" $::closed {20}

puts "an engine that dies mid-pass"
set ::sent {}
set ::closed {}
set ::done {}
set ::progress {}
set token [::reviewdriver::start $enginecfg {{4 {fen A}} {5 {fen B}} {6 {fen C}}} 3 18 ::onProgress ::onDone]
feed InfoConfig {}
feed InfoPV {1 10 11 0 0 0 0 10 cp 0 e2e4}
feed InfoBestMove {}
feed InfoPV {1 9 9 0 0 0 0 20 cp 0 d2d4}
feed InfoDisconnected {}
checkEq "the pass still completes, with what it had" [dict keys $::done] {4}
checkEq "no position after the loss is started" \
    [lsearch -all -inline -glob $::sent {send 20 Go*}] \
    [list {send 20 Go {{fen A} {depth 18}}} {send 20 Go {{fen B} {depth 18}}}]
checkEq "nothing is closed: the connection is already gone" $::closed {}
checkEq "and the dead pass is forgotten" [::reviewdriver::stop $token] 0

puts "a close queued by one pass does not close the next"
set ::sent {}
set ::closed {}
set first [::reviewdriver::start $enginecfg {{4 {fen A}}} 2 18 ::onProgress ::onDone]
feed InfoConfig {}
feed InfoBestMove {}
checkEq "the id is free the moment the last reply is in" [::reviewdriver::busy 20] 0
set second [::reviewdriver::start $enginecfg {{4 {fen A}}} 2 18 ::onProgress ::onDone]
pump
checkEq "the queued close leaves the new connection alone" $::closed {}
feed InfoConfig {}
feed InfoBestMove {}
pump
checkEq "and the pass that owns it still closes it" $::closed {20}

puts "\n$checks checks, $fails failures"
exit [expr {$fails ? 1 : 0}]
