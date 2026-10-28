#!/usr/bin/env tclsh
# Copyright (C) 2026 David Crandall
# SPDX-License-Identifier: GPL-2.0-or-later
#
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
    {Empty /x {} {} 0 0 {} 1 {} {}}
    {Legacy /x {} {} 0 0 {} 1 {}}
    {Invalid /x {} {} 0 0 {} 1 {} {depth 0 movetime abc}}
}
set fallback [list depth 7 movetime 1000]
checkEq "a complete preset" [::enginelimits::forName Deep $fallback] \
    {depth 66 movetime 300000 autorun {}}
# A preset that carries Limits is authoritative: an empty key means "no limit",
# which is how the window stores a blank depth or time field. Falling back to a
# legacy global here would make "unlimited" impossible to express.
checkEq "a preset's empty key means no limit" [::enginelimits::forName Quick $fallback] \
    {depth 18 movetime {} autorun {}}
checkEq "an explicit empty Limits is authoritative too" \
    [::enginelimits::forName Empty $fallback] {depth {} movetime {} autorun {}}
checkEq "a legacy entry is all fallback" [::enginelimits::forName Legacy $fallback] \
    {depth 7 movetime 1000 autorun {}}
checkEq "invalid values in the file are dropped" \
    [::enginelimits::forName Invalid $fallback] {depth {} movetime {} autorun {}}
checkEq "an unknown engine is all fallback" [::enginelimits::forName Nope $fallback] \
    {depth 7 movetime 1000 autorun {}}

puts "the file"
# The test file lives in the OS temp directory, as the other harnesses do, so
# an aborted run cannot leave it in the source tree.
set ::tmpbase [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) \
                 : [info exists ::env(TEMP)] ? $::env(TEMP) : "/tmp"}]
set ::tmp [file join $::tmpbase "scid_engine_limits_[pid].dat"]
proc scidConfigFile {type} { return $::tmp }
set ::scidVersion 5.0

puts "saving one limit keeps the rest"

# The window's depth/time editor saves what it shows. It does not show autorun
# and must not wipe it.
set ::engines(list) [list [list Deep /x {} {} 0 0 {} 1 {} \
    [dict create depth 66 movetime 300000 autorun 250]]]
::enginelimits::saveFor Deep [list depth 30 movetime 50]
set saved [::enginelimits::of [lindex $::engines(list) 0]]
checkEq "a save keeps a depth it was not asked to change" [dict get $saved depth] 30
checkEq "and the autorun it never showed" [dict get $saved autorun] 250
# An explicitly empty value clears the key, and the file stops carrying it.
::enginelimits::saveFor Deep [list depth ""]
set saved [::enginelimits::of [lindex $::engines(list) 0]]
checkEq "an empty value clears the depth" [dict get $saved depth] {}
checkEq "and keeps the rest" [dict get $saved movetime] 50
check "an invalid value is refused" [expr {[catch {::enginelimits::saveFor Deep [list depth 0]}]}]

# A loaded preset's option list is {name value} pairs, not the live widget
# definitions: save must accept both, or a depth edit throws for every engine
# with a stored Threads/Hash.
set ::engines(list) [list [list Deep /x {} {} 0 0 {} 1 {{Threads 4} {Hash 256}} {depth 66}]]
::enginecfg::save [lindex $::engines(list) 0]
checkEq "a save keeps the stored UCI options" \
    [lindex [lindex $::engines(list) 0] 8] {{Threads 4} {Hash 256}}
checkEq "and the limit survives it" \
    [dict get [::enginelimits::of [lindex $::engines(list) 0]] depth] 66

# The window's live record is written back on an option change; it has to learn
# about a limit saved from the field, or that save would erase it.
set ::enginecfg::engConfig_1 [list Deep /x {} {} 0 0 {} 1 {} {depth 66}]
::enginelimits::saveFor Deep [list depth 30]
checkEq "an open window follows a limit save" [lindex $::enginecfg::engConfig_1 9] {depth 30}
unset ::enginecfg::engConfig_1

if {$haveLoader} {
    # Write a preset with limits and a legacy preset, then read the file back:
    # the loader check must use what ::enginecfg::write emitted, not a stanza
    # constructed to suit it.
    set ::engines(list) [list \
        [list Deep /x {} {} 0 0 {} 1 {} [dict create depth 66 movetime 300000]] \
        [list Legacy /x {} {} 0 0 {} 1 {}]]
    ::enginecfg::write
    set written [read [set f [open $::tmp r]]]
    close $f
    check "the preset with limits writes them" [string match {*Limits*} $written]
    checkEq "and writes them once" [regexp -all {Limits} $written] 1

    set ::engines(list) {}
    source $::tmp
    checkEq "the loader reads the written depth back" \
        [dict get [::enginelimits::of [::enginecfg::get Deep]] depth] 66
    checkEq "and the written movetime" \
        [dict get [::enginelimits::of [::enginecfg::get Deep]] movetime] 300000
    checkEq "a legacy entry still has nine elements" \
        [llength [::enginecfg::get Legacy]] 9
    engine {Name Bare Cmd /x Dir {} Limits 20}
    checkEq "a bare integer is taken as the depth" \
        [dict get [::enginelimits::of [::enginecfg::get Bare]] depth] 20
    engine {Name Zero Cmd /x Dir {} Limits 0}
    checkEq "and an invalid bare integer is dropped at use" \
        [dict get [::enginelimits::forName Zero] depth] {}
} else {
    # A silent skip would let the file-format round trip rot unnoticed.
    puts "  FAIL the engine list loader could not be extracted"
    incr fails
}

# The write-only path, independent of the loader.
set ::engines(list) [list [list Deep /x {} {} 0 0 {} 1 {} [dict create depth 66]]]
::enginecfg::write
set written [read [set f [open $::tmp r]]]
close $f
check "a file with a preset limit carries it" [string match {*  Limits {depth 66}*} $written]
set ::engines(list) [list [list Empty /x {} {} 0 0 {} 1 {} {}]]
::enginecfg::write
set written [read [set f [open $::tmp r]]]
close $f
check "a preset whose limits were all cleared still writes the field" \
    [string match {*  Limits {}*} $written]
set ::engines(list) [list [list Legacy /x {} {} 0 0 {} 1 {}]]
::enginecfg::write
set written [read [set f [open $::tmp r]]]
close $f
check "a legacy entry writes no Limits line" \
    [expr {[string first "Limits" $written] < 0}]

file delete -force $::tmp

puts "\n$checks checks, $fails failures"
exit [expr {$fails ? 1 : 0}]
