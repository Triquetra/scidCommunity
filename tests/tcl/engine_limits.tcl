#!/usr/bin/env tclsh
# Search limits that belong to an engine preset: the data layer, the file
# format, and what the engine window derives from both.

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
source [file join $root tcl tools engine_limits.tcl]
source [file join $root tcl enginecfg.tcl]

# The engine list loader lives in a file that needs the Tk globals, so take
# just the proc: it is the part that reads the file format.
set haveLoader 0
if {[catch {
    set f [open [file join $root tcl tools enginelist.tcl] r]
    set src [read $f]
    close $f
    set from [string first "proc engine {arglist}" $src]
    set to [string first "\nproc ::enginelist::read" $src]
    eval [string range $src $from [expr {$to - 1}]]
    set haveLoader 1
} err]} {
    puts "  (engine list loader not extracted ($err); format round-trip skipped)"
}

puts "the entry layout"
set legacy {Stockfish /usr/bin/stockfish {} {} 0 0 {} 1 {}}
checkEq "a legacy entry grows to ten elements" [llength [::enginelimits::pad $legacy]] 10
set empty [::enginelimits::of [::enginelimits::pad $legacy]]
checkEq "and gains no depth" [dict get $empty depth] {}
checkEq "and no movetime" [dict get $empty movetime] {}
set kept [::enginelimits::of {A /x {} {} 0 0 {} 1 {} {depth 18}}]
checkEq "an entry that already has limits keeps its depth" [dict get $kept depth] 18
checkEq "and gains no movetime" [dict get $kept movetime] {}

puts "what a limit may be"
check "empty means not set" [::enginelimits::valid depth {}]
check "a depth of 18 is fine" [::enginelimits::valid depth 18]
check "zero is not a limit" [expr {![::enginelimits::valid depth 0]}]
check "a depth beyond 500 is refused" [expr {![::enginelimits::valid depth 501]}]
check "words are refused" [expr {![::enginelimits::valid movetime abc]}]
check "a movetime in ms is accepted" [::enginelimits::valid movetime 250]

puts "setting one limit"
set e [::enginelimits::setLimit $legacy depth 18]
checkEq "the depth lands in the preset" [dict get [::enginelimits::of $e] depth] 18
checkEq "the other keys stay empty" [dict get [::enginelimits::of $e] movetime] {}
set e [::enginelimits::setLimit $e movetime 250]
checkEq "and a second limit joins it" [::enginelimits::goLimits [::enginelimits::of $e]] \
    {{depth 18} {movetime 250}}
check "an unknown limit is refused" \
    [expr {[catch {::enginelimits::setLimit $legacy threads 8}]}]
check "an out-of-range value is refused" \
    [expr {[catch {::enginelimits::setLimit $legacy depth 0}]}]

puts "what the search is told"
checkEq "no limits, no list" [::enginelimits::goLimits {depth {} movetime {}}] {}
checkEq "depth only" [::enginelimits::goLimits {depth 30}] {{depth 30}}
checkEq "movetime only" [::enginelimits::goLimits {movetime 500}] {{movetime 500}}

puts "which limits a window uses"
set ::engines(list) {
    {Deep /x {} {} 0 0 {} 1 {} {depth 66 movetime 300000}}
    {Quick /x {} {} 0 0 {} 1 {} {depth 18}}
    {Legacy /x {} {} 0 0 {} 1 {}}
}
set fallback [list depth {} movetime 1000]
checkEq "a complete preset" [::enginelimits::forName Deep $fallback] \
    {depth 66 movetime 300000 autorun {}}
checkEq "an unset key falls back" [::enginelimits::forName Quick $fallback] \
    {depth 18 movetime 1000 autorun {}}
checkEq "a legacy entry is all fallback" [::enginelimits::forName Legacy $fallback] \
    {depth {} movetime 1000 autorun {}}
checkEq "an unknown engine is all fallback" [::enginelimits::forName Nope $fallback] \
    {depth {} movetime 1000 autorun {}}

puts "the file"
set ::tmp [file join [file dirname [info script]] .. .. cache_engine_limits.dat]
set ::tmp [file normalize $::tmp]
proc scidConfigFile {type} { return $::tmp }
set ::scidVersion 5.0

if {$haveLoader} {
    # Write one preset with limits and one without, then read them back.
    set ::engines(list) [list \
        [list Deep /x {} {} 0 0 {} 1 {} [dict create depth 66 movetime 300000]] \
        [list Legacy /x {} {} 0 0 {} 1 {} {}]]
    ::enginecfg::write
    set written [read [set f [open $::tmp r]]]
    close $f
    check "the preset with limits writes them" [string match {*Limits*} $written]
    checkEq "and writes them once" [regexp -all {Limits} $written] 1

    set ::engines(list) {}
    engine {Name Deep Cmd /x Dir {} Limits {depth 66 movetime 300000}}
    engine {Name Legacy Cmd /x Dir {}}
    checkEq "the loader reads them back" [dict get [::enginelimits::of [::enginecfg::get Deep]] depth] 66
    checkEq "a preset without limits loads with none" \
        [dict get [::enginelimits::of [::enginecfg::get Legacy]] depth] {}
    engine {Name Bare Cmd /x Dir {} Limits 20}
    checkEq "a bare integer is taken as the depth" \
        [dict get [::enginelimits::of [::enginecfg::get Bare]] depth] 20
} else {
    puts "  (engine list loader unavailable here; format round-trip skipped)"
}

# The write-only path, independent of the loader.
set ::engines(list) [list [list Deep /x {} {} 0 0 {} 1 {} [dict create depth 66]]]
::enginecfg::write
set written [read [set f [open $::tmp r]]]
close $f
check "a file with a preset limit carries it" [string match {*  Limits {depth 66}*} $written]
set ::engines(list) [list [list Legacy /x {} {} 0 0 {} 1 {} {}]]
::enginecfg::write
set written [read [set f [open $::tmp r]]]
close $f
check "a preset with no limits writes no Limits line" \
    [expr {[string first "Limits" $written] < 0}]

file delete -force $::tmp

puts "\n$checks checks, $fails failures"
exit [expr {$fails ? 1 : 0}]
