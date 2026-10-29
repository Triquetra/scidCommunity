#!/usr/bin/env tclsh
# Copyright (C) 2026 David Crandall
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Duplicating an engine preset.
#
#   tclsh tests/tcl/engine_duplicate.tcl
#
# A duplicate has to be a *complete* spec: the binary, its arguments and
# directory, the whole UCI option list and the search limits - under a new
# name. Two shapes of "no limits" have to survive it, because they mean
# different things:
#
#   * a legacy nine-element entry has no Limits field, so it keeps falling back
#     to the old global settings, and its copy must not grow a Limits line;
#   * an entry whose limits were all cleared carries an explicit empty dict,
#     which is what overrides those globals, so its copy must keep it.
#
# The second half is the part the limits work's own tests missed: a copy that
# merely pads to ten elements turns both cases into "Limits {}", and one that
# drops element 9 turns the second into a legacy entry.

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

# Call a command whose procedure may not exist yet (or may throw): a failed
# check, not a dead harness.
proc call {cmd} {
    if {[catch {uplevel 1 $cmd} res]} { return "ERR: $res" }
    return $res
}

set root [file normalize [file join [file dirname [info script]] .. ..]]
source [file join $root tcl tools engine_limits.tcl]
source [file join $root tcl enginecfg.tcl]

set ::tmpbase [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) \
                 : [info exists ::env(TEMP)] ? $::env(TEMP) : "/tmp"}]
set ::tmp [file join $::tmpbase "scid_engine_duplicate_[pid].dat"]
proc scidConfigFile {type} { return $::tmp }
set ::scidVersion 5.0

# enginelist.tcl needs Tk for its dialogs, so the procs under test are lifted
# out of it by name, the way the limits harness lifts the loader. A proc that
# has been renamed or moved fails loudly instead of passing silently.
proc procText {path name} {
    set f [open $path r]
    set src [read $f]
    close $f
    set from [string first "proc $name " $src]
    if {$from < 0} { return "" }
    # Take whole lines until the definition is balanced: the text after a proc
    # may be another proc, or top-level code that would run here if included.
    set text ""
    foreach line [split [string range $src $from end] "\n"] {
        append text $line "\n"
        if {[info complete $text]} { break }
    }
    return $text
}

set enginelistFile [file join $root tcl tools enginelist.tcl]
namespace eval enginelist {}
foreach name {engine ::enginelist::read ::enginelist::applyEdit ::enginelist::nameTaken \
              ::enginelist::saveEdit ::enginelist::duplicate} {
    set text [procText $enginelistFile $name]
    if {$text eq ""} {
        puts "FAIL the engine list's $name could not be extracted"
        incr fails
        incr checks
        continue
    }
    eval $text
}
# The real ones open windows and re-sort the table; the harness only needs to
# know an edit was asked for, and at which index.
set ::edited {}
proc ::enginelist::edit {index} { set ::edited $index }
proc ::enginelist::sort {{type ""}} {}
# The edit dialog's side effects outside the list: the engine window's own
# saved state, and the question it asks before it will not write.
namespace eval engineNoWin {}
proc ::engineNoWin::saveEngineSetup {args} {}
set ::tr(EngineNameInUse) {An engine named %s already exists. Save this one as %s instead?}
set ::asked {}
set ::answer yes
proc tk_messageBox {args} {
    lappend ::asked $args
    return $::answer
}

# The list and the file it saves, as the loader would have left them.
proc reload {} {
    set ::engines(list) {}
    if {[file exists $::tmp]} { source $::tmp }
}
proc fileText {} {
    if {![file exists $::tmp]} { return "" }
    set f [open $::tmp r]
    set text [read $f]
    close $f
    return $text
}

puts "a copy is a complete spec"
set src {Deep /usr/bin/sf {--uci} /opt/sf 2800 100 {white 1 none false normal {}} 1 \
    {{Threads 4} {Hash 256} {SyzygyPath /tb}} {depth 66 movetime 300000 autorun 250}}
set ::engines(list) [list $src]
set copy [call {::enginecfg::duplicate $src}]
checkEq "the copy takes a new name" [call {lindex [::enginecfg::duplicate $src] 0}] {Deep (1)}
checkEq "and changes nothing after it" \
    [call {lrange [::enginecfg::duplicate $src] 1 end}] [lrange $src 1 end]
checkEq "the command, arguments and directory come with it" [lrange $copy 1 3] \
    [lrange $src 1 3]
checkEq "the whole UCI option list comes with it" [lindex $copy 8] \
    {{Threads 4} {Hash 256} {SyzygyPath /tb}}
checkEq "the limits come with it" [lindex $copy 9] {depth 66 movetime 300000 autorun 250}
checkEq "and the list is left alone" $::engines(list) [list $src]

puts "names"
set ::engines(list) [list [list Deep /x {} {} 0 0 {} 1 {}] \
                          [list {Deep (1)} /x {} {} 0 0 {} 1 {}]]
checkEq "a second copy counts up" \
    [call {lindex [::enginecfg::duplicate [lindex $::engines(list) 0]] 0}] {Deep (2)}

puts "a legacy entry copies as a legacy entry"
set legacy {Legacy /x {} {} 0 0 {} 1 {{Threads 2}}}
set ::engines(list) [list $legacy]
set copy [call {::enginecfg::duplicate $legacy}]
checkEq "a nine-element source copies as nine" [call {llength [::enginecfg::duplicate $legacy]}] 9
checkEq "the copy keeps the option list" [lindex $copy 8] {{Threads 2}}

set ::engines(list) [list $legacy]
set newName [call {::enginelist::duplicate 0}]
checkEq "the list gains the copy" [llength $::engines(list)] 2
checkEq "under a unique name" $newName {Legacy (1)}
check "the copy is written" [expr {[string first "Name {Legacy (1)}" [fileText]] >= 0}]
check "and wrote no Limits line" [expr {[string first "Limits" [fileText]] < 0}]
reload
checkEq "the reloaded copy is still nine elements" \
    [call {llength [::enginecfg::get {Legacy (1)}]}] 9
checkEq "so its limits still fall back to the globals" \
    [::enginelimits::forName {Legacy (1)} {depth 7 movetime 1000}] {depth 7 movetime 1000 autorun {}}
checkEq "and the copy is opened for renaming" $::edited \
    [expr {[lsearch -exact -index 0 $::engines(list) {Legacy (1)}]}]

puts "all limits cleared survives the copy"
set cleared {Empty /x {} {} 0 0 {} 1 {{Threads 2}} {}}
set ::engines(list) [list $cleared]
set copy [call {::enginecfg::duplicate $cleared}]
checkEq "a source with an empty Limits copies as ten elements" \
    [call {llength [::enginecfg::duplicate $cleared]}] 10
checkEq "and the empty dict is the copy's tenth" \
    [call {lindex [::enginecfg::duplicate $cleared] 9}] {}
checkEq "the copy keeps the option list" [lindex $copy 8] {{Threads 2}}

set ::engines(list) [list $cleared]
set ::edited {}
set newName [call {::enginelist::duplicate 0}]
checkEq "the copy is written with an explicit empty Limits" \
    [string match {*  Limits {}*} [fileText]] 1
reload
checkEq "the reloaded copy has ten elements" \
    [call {llength [::enginecfg::get {Empty (1)}]}] 10
checkEq "and its limits stay cleared" \
    [::enginelimits::forName {Empty (1)} {depth 7 movetime 1000}] {depth {} movetime {} autorun {}}
checkEq "the empty Limits survives a second reload" \
    [dict get [::enginelimits::of [::enginecfg::get {Empty (1)}]] depth] {}

puts "renaming the copy keeps the rest"
# The edit dialog shows name/command/args/dir/elo/time/url/uci/options and
# nothing else, so it must put back whatever the entry carried beyond them.
set fields {Empty /x {} {} 0 0 {} 1 {{Threads 2}}}
set ::engines(list) [list $cleared]
set ::edited {}
checkEq "a rename keeps the limits" \
    [call {lindex [::enginelist::applyEdit 0 $fields] 9}] {}
set renamed [list {Empty Renamed} /x {} {} 0 0 {} 1 {{Threads 2}}]
set ::engines(list) [list $cleared]
call {::enginelist::applyEdit 0 $renamed}
checkEq "the renamed entry has ten elements" [llength [lindex $::engines(list) 0]] 10
checkEq "and is stored under the new name" [lindex [lindex $::engines(list) 0] 0] {Empty Renamed}
set ::engines(list) [list {Deep /x {} {} 0 0 {} 1 {} {depth 66 movetime 300000}}]
call {::enginelist::applyEdit 0 {Deep2 /x {} {} 0 0 {} 1 {}}}
checkEq "a rename keeps a preset's limits too" \
    [dict get [::enginelimits::of [lindex $::engines(list) 0]] depth] 66
set ::engines(list) [list {Legacy /x {} {} 0 0 {} 1 {}}]
call {::enginelist::applyEdit 0 {Legacy2 /x {} {} 0 0 {} 1 {}}}
checkEq "a legacy entry stays nine elements after a rename" \
    [llength [lindex $::engines(list) 0]] 9

puts "a rename cannot take another preset's name"
# The list is read by name, so two entries under one name leave the second
# unreachable. A rename is how a duplicate turns into that, so the edit has to
# refuse it - and the file must not be touched when it does.
set deep [list Deep /x {} {} 0 0 {} 1 {{Threads 4}} {depth 66}]
set deep1 [list {Deep (1)} /x {} {} 0 0 {} 1 {{Threads 2}} {depth 18}]
set renameOnto [list Deep /x {} {} 0 0 {} 1 {{Threads 2}}]
set ::engines(list) [list $deep $deep1]
::enginecfg::write
set before [fileText]
set ::answer no
set ::asked {}
check "the clash is seen" [expr {[::enginelist::nameTaken 1 Deep]}]
check "an entry's own name is not a clash" [expr {![::enginelist::nameTaken 0 Deep]}]
check "a free name is not a clash" [expr {![::enginelist::nameTaken 0 Nope]}]
checkEq "so a rename onto it is refused" [::enginelist::saveEdit 1 $renameOnto] false
checkEq "the list keeps both entries" [llength $::engines(list)] 2
checkEq "the edited entry keeps its own name" [lindex [lindex $::engines(list) 1] 0] {Deep (1)}
checkEq "and the file is not written" [fileText] $before
checkEq "the question offers the name a duplicate would take" \
    [string match {*Deep (2)*} $::asked] 1

set ::answer yes
set ::asked {}
checkEq "accepting the suggestion writes the edit" [::enginelist::saveEdit 1 $renameOnto] true
checkEq "under the suggested name" [lindex [lindex $::engines(list) 1] 0] {Deep (2)}
checkEq "the original entry is untouched" [lindex [lindex $::engines(list) 0] 0] Deep
checkEq "and keeps its own limits" \
    [dict get [::enginelimits::of [lindex $::engines(list) 0]] depth] 66
checkEq "so does the renamed one" \
    [dict get [::enginelimits::of [lindex $::engines(list) 1]] depth] 18
set names {}
foreach e $::engines(list) { lappend names [lindex $e 0] }
checkEq "one name, one entry" [llength [lsort -unique $names]] [llength $names]
::enginecfg::write
reload
checkEq "and the file holds the suggested name" \
    [call {llength [::enginecfg::get {Deep (2)}]}] 10

set ::asked {}
checkEq "an edit that keeps its own name is saved without asking" \
    [::enginelist::saveEdit 0 [list Deep /x {} {} 0 0 {} 1 {{Threads 4}}]] true
checkEq "without a question" [llength $::asked] 0
checkEq "and keeps its limits" \
    [dict get [::enginelimits::of [lindex $::engines(list) 0]] depth] 66

puts "the story end to end: duplicate, rename, reload"
set ::engines(list) [list {Deep /x {--threads 8} /opt 2800 100 \
    {white 1 none false normal {}} 1 {{Threads 8} {Hash 512}} {depth 66 movetime 300000}}]
set ::edited {}
call {::enginelist::duplicate 0}
call {::enginelist::applyEdit $::edited [list {Quick Review} /x {--threads 8} /opt \
    2800 100 {white 1 none false normal {}} 1 {{Threads 8} {Hash 512}}]}
::enginecfg::write
reload
checkEq "the renamed duplicate keeps its UCI options" \
    [call {lindex [::enginecfg::get {Quick Review}] 8}] {{Threads 8} {Hash 512}}
checkEq "and its limits" \
    [dict get [::enginelimits::of [::enginecfg::get {Quick Review}]] movetime] 300000
checkEq "and its command" [call {lindex [::enginecfg::get {Quick Review}] 1}] /x
checkEq "and the source is untouched" [call {llength [::enginecfg::get Deep]}] 10

puts "the list dialog offers it"
# The dialog itself needs Tk and a display, so what can be checked here is that
# the control is still there and still calls the two procs above: a harness
# that only covered the data layer would let the button be dropped silently.
set fh [open $enginelistFile r]
set dialogSrc [read $fh]
close $fh
check "the list dialog has a Duplicate button" [string match {*$f.duplicate*} $dialogSrc]
check "wired to ::enginelist::duplicate" \
    [regexp {dialogbutton \$f\.duplicate[^\n]*\n[^\n]*::enginelist::duplicate} $dialogSrc]
check "packed with the other list buttons" \
    [string match {*$f.edit $f.duplicate $f.delete*} $dialogSrc]
check "the edit dialog stores through saveEdit" \
    [string match {*::enginelist::saveEdit $engines(newIndex)*} $dialogSrc]
set saveAt [string first "proc ::enginelist::saveEdit" $dialogSrc]
check "saveEdit checks the name before it writes" \
    [expr {$saveAt >= 0 &&
            [string first "::enginelist::nameTaken" $dialogSrc $saveAt] > $saveAt &&
            [string first {::enginelist::applyEdit $index $fields} $dialogSrc $saveAt] > $saveAt}]

file delete -force $::tmp

puts "\n$checks checks, $fails failures"
exit [expr {$fails ? 1 : 0}]
