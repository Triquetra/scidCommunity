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
source [file join $root tcl tools game_review.tcl]
source [file join $root tcl tools review_driver.tcl]

# The engine layer, stubbed: the driver's job is which messages it sends and
# what it does with the replies, not how a pipe to Stockfish works.
set ::sent {}
set ::closed {}
namespace eval ::engine {}
proc ::engine::setLogCmd {id args} {}
proc ::engine::connect {id callback exe args} {
    set ::engconn(channel_$id) opened
    set ::engine_callback $callback
    lappend ::sent [list connect $id $exe $args]
}
proc ::engine::send {id msg args} {
    lappend ::sent [list send $id $msg [lindex $args 0]]
}
proc ::engine::close {id} {
    unset -nocomplain ::engconn(channel_$id)
    lappend ::closed $id
}

proc feed {msgType msgData} {
    {*}$::engine_callback [list $msgType $msgData]
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
checkEq "an engine that advertises nothing leaves them unset" \
    [dict get [::review::engineDefaults {X /x {} {} 0 0 {} 1 {}}] threads] {}
checkEq "and then ::review's value is the fallback" \
    [dict get [::review::effective {X /x {} {} 0 0 {} 1 {}}] threads] [::review::get threads]

puts "a pass over three positions"
set ::progress {}
set ::done ""
proc onProgress {n total ply lines} { lappend ::progress [list $n $total $ply] }
proc onDone {results} { set ::done $results }
set positions {{4 {fen A}} {5 {fen B}} {6 {fen C}}}
set token [::reviewdriver::start $enginecfg $positions 3 18 ::onProgress ::onDone]
checkEq "the engine was opened on the pass's own id" [lindex $::sent 0] {connect 20 /usr/bin/stockfish uci}
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

checkEq "the engine is closed at the end" $::closed {20}
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
checkEq "the engine is closed" [lindex $::closed 1] 20
checkEq "no further search is started" [lsearch -all -inline -glob $::sent {send 20 Go*}] $searches
checkEq "and the pass is forgotten" [::reviewdriver::stop $token] 0

puts "\n$checks checks, $fails failures"
exit [expr {$fails ? 1 : 0}]
