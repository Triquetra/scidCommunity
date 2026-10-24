# harness.tcl <plugin.tcl> <expected rows> <expected source label>
# Stubs just enough Tk to load and drive the plugin's wheel path.

set plugin  [lindex $argv 0]
set expRows [lindex $argv 1]
set expSrc  [lindex $argv 2]
set ::REGVAL [lindex $argv 3]

set ::FAIL 0
set ::N    0
proc ok {label cond {extra ""}} {
    incr ::N
    if {[expr $cond]} {
        puts "PASS $label"
    } else {
        incr ::FAIL
        puts "FAIL $label  $extra"
    }
}

# ---- stubs -----------------------------------------------------------------
proc tk {args} { return win32 }

array set ::BINDS {}
proc bind {tag seq args} {
    if {[llength $args] == 0} { return [expr {[info exists ::BINDS($tag,$seq)] ? $::BINDS($tag,$seq) : ""}] }
    set ::BINDS($tag,$seq) [lindex $args 0]
}

# misc.tcl, win32 branch
proc bindMouseWheel {bindtag callback} {
    bind $bindtag <MouseWheel> "[append callback { [expr {-%D/120}]}]; break"
}

set ::YBCALL {}
proc glist.ybar_ {w cmd {n 0} {units ""}} {
    lappend ::YBCALL [list $w $cmd $n $units]
}

proc winfo {sub args} {
    if {$sub eq "children"} { return {} }
    return 0
}

# Optional: fake the Windows registry so the WheelScrollLines branch is exercised.
if {[llength $argv] > 3} {
    rename package realPackage
    proc package {sub args} {
        if {$sub eq "require" && [lindex $args 0] eq "registry"} { return registry }
        return [realPackage $sub {*}$args]
    }
    proc registry {sub key {value ""}} {
        if {$sub eq "get" && $value eq "WheelScrollLines"} { return $::REGVAL }
        error "registry $sub $key $value: not stubbed"
    }
}

# ---- load ------------------------------------------------------------------
source $plugin

ok "rows = $expRows"  $::glw::rows==$expRows "got $::glw::rows"
ok "source = $expSrc" [string match $expSrc $::glw::src] "got '$::glw::src'"

# ---- binding interception --------------------------------------------------
bindMouseWheel .w0.glist "glist.ybar_ .w0.glist"
set s $::BINDS(.w0.glist,<MouseWheel>)
ok "game list gets ::glw::wheel" [string match {*::glw::wheel*} $s] "got '$s'"
ok "game list binding breaks"     [string match {*break*} $s] "got '$s'"

bindMouseWheel .main.board "main_mousewheelHandler"
set b $::BINDS(.main.board,<MouseWheel>)
ok "board keeps core binding" [string match {*main_mousewheelHandler*} $b] "got '$b'"
ok "board not rerouted"       [expr {![string match {*::glw::*} $b]}] "got '$b'"

bindMouseWheel .main.ybar "_autoscrollMouseWheel"
set a $::BINDS(.main.ybar,<MouseWheel>)
ok "autoscroll bar keeps core binding" [string match {*_autoscrollMouseWheel*} $a] "got '$a'"

# ---- wheel driving ---------------------------------------------------------
set w .w0.glist

# one notch down = +rows
set ::YBCALL {}
::glw::wheel $w -120
ok "one notch down scrolls $expRows rows" [expr {$::YBCALL eq [list [list $w scroll $expRows units]]}] "got '$::YBCALL'"

# one notch up = -rows
set ::YBCALL {}
::glw::wheel $w 120
ok "one notch up scrolls -$expRows rows" [expr {$::YBCALL eq [list [list $w scroll -$expRows units]]}] "got '$::YBCALL'"

# sub-notch deltas accumulate instead of being dropped
set ::YBCALL {}
::glw::wheel $w -60
ok "half a notch does nothing yet" [expr {[llength $::YBCALL]==0}] "got '$::YBCALL'"
::glw::wheel $w -60
ok "second half notch scrolls" [expr {$::YBCALL eq [list [list $w scroll $expRows units]]}] "got '$::YBCALL'"

# leftover is not lost
set ::YBCALL {}
::glw::wheel $w -60
::glw::wheel $w -60
::glw::wheel $w -30
ok "leftover 30 kept (no scroll)" [expr {[llength $::YBCALL]==1}] "got '$::YBCALL'"
::glw::wheel $w -90
ok "30 + 90 = one notch" [expr {[llength $::YBCALL]==2 && [lindex $::YBCALL 1] eq [list $w scroll $expRows units]}] "got '$::YBCALL'"

# a fast spin (3 notches in one event) scrolls 3x
set ::YBCALL {}
::glw::wheel $w -360
ok "3-notch event scrolls 3x" [expr {$::YBCALL eq [list [list $w scroll [expr {3*$expRows}] units]]}] "got '$::YBCALL'"

# accumulators are per widget
set ::YBCALL {}
::glw::wheel .w1.glist -60
::glw::wheel $w 120
ok "accumulator is per widget" [expr {[llength $::YBCALL]==1 && [lindex $::YBCALL 0 2]==[expr {-$expRows}]}] "got '$::YBCALL'"

# ---- log -------------------------------------------------------------------
set lf [file join [file dirname $plugin] glist_wheel.log]
ok "log written" [file readable $lf]
set lt ""
catch {set fh [open $lf r]; set lt [read $fh]; close $fh}
ok "log names the value and source" [string match "*rows per notch = $expRows (from*" $lt] "'$lt'"
ok "log done line" [string match {*load done*} $lt]

puts "--"
if {$::FAIL} { puts "FAILURES: $::FAIL of $::N"; exit 1 }
puts "all $::N checks passed"
exit 0
