# 09_glist_wheel.tcl ---------------------------------------------------------
# Mouse wheel speed for scid's game list (the main database window).
#
# windows/gamelist.tcl binds the wheel as
#     bindMouseWheel $w.glist "glist.ybar_ $w.glist"
# and bindMouseWheel (misc.tcl) turns one wheel notch into +/-1, so
# glist.ybar_ moves the list by exactly ONE row -- and every notch deletes
# and refills the whole visible window through "sc_base gameslist".  Windows'
# own default is WheelScrollLines rows (normally 3), so the list feels stuck.
#
# This plugin intercepts the wheel binding for game-list widgets only.  It
# scrolls N rows per notch and accumulates sub-notch deltas (precision
# touchpads send fractions of a notch, which the core binding truncates to
# zero and silently drops).
#
# Rows per notch:  plugins/glist_wheel.dat   -- one integer, 1..100
#                  otherwise Windows Control Panel > Mouse > lines per notch
#                  otherwise 3
# Log:             plugins/glist_wheel.log
# ---------------------------------------------------------------------------

namespace eval ::glw {
    variable rows  3
    variable src   "default"
    variable acc
    variable dir   ""
    variable logh  ""
}

set ::glw::dir [file dirname [info script]]

proc ::glw::log {msg} {
    variable logh
    if {$logh eq ""} { return }
    # a failing timestamp must not cost the line itself
    set ts "-"
    catch {set ts [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]}
    catch {
        puts $logh "$ts $msg"
        flush $logh
    }
}

# Rows per wheel notch: settings file, else the Windows system value, else 3.
proc ::glw::resolveRows {} {
    variable rows
    variable src
    variable dir

    set f [file join $dir glist_wheel.dat]
    if {[file readable $f]} {
        set txt ""
        if {![catch {open $f r} fh]} {
            set txt [read $fh]
            close $fh
        }
        if {[regexp {([0-9]+)} $txt -> num] && $num >= 1 && $num <= 100} {
            set rows $num
            set src "glist_wheel.dat"
            return
        }
        ::glw::log "glist_wheel.dat has no usable integer (1..100); using the system value"
    }

    set rows 3
    set src "default"
    if {![catch {package require registry}]} {
        set v ""
        catch {set v [registry get {HKEY_CURRENT_USER\Control Panel\Desktop} WheelScrollLines]}
        if {[string is integer -strict $v] && $v >= 1 && $v <= 100} {
            set rows $v
            set src "Windows WheelScrollLines"
        }
    }
}

# One wheel notch on win32: %D is +/-120 (or a multiple for a fast spin).
# Fractional deltas are kept in a per-widget accumulator instead of dropped.
proc ::glw::wheel {w delta} {
    variable acc
    if {![info exists acc($w)]} { set acc($w) 0 }
    set acc($w) [expr {$acc($w) + $delta}]
    set notch [expr {int($acc($w) / 120.0)}]
    if {$notch == 0} { return }
    set acc($w) [expr {$acc($w) - $notch * 120}]
    # a negative Windows delta means the wheel turned towards the user (down)
    ::glw::scroll $w [expr {-$notch}]
}

# aqua delivers a small direction value, not a 120-unit delta.
proc ::glw::wheelDir {w delta} {
    ::glw::scroll $w [expr {-$delta}]
}

# dir: -1 = up, +1 = down
proc ::glw::scroll {w dir} {
    variable rows
    set n [expr {$dir * $rows}]
    if {[catch {glist.ybar_ $w scroll $n units} err]} {
        ::glw::log "scroll failed for $w: $err"
    }
}

proc ::glw::bindWheel {bindtag} {
    switch -- [tk windowingsystem] {
        x11 {
            bind $bindtag <Button-4> {::glw::scroll %W -1; break}
            bind $bindtag <Button-5> {::glw::scroll %W +1; break}
            bind $bindtag <MouseWheel> {::glw::wheel %W %D; break}
        }
        aqua {
            bind $bindtag <MouseWheel> {::glw::wheelDir %W %D; break}
        }
        default {
            bind $bindtag <MouseWheel> {::glw::wheel %W %D; break}
        }
    }
}

# Replace the core binding helper, but only for game-list widgets: the board
# (main_mousewheelHandler) and the autoscroll bars keep their own behaviour.
proc ::glw::wrap {} {
    if {[llength [info commands ::glw::coreBindMouseWheel]] > 0} {
        ::glw::log "bindMouseWheel already wrapped; not wrapping twice"
        return
    }
    if {[llength [info commands ::bindMouseWheel]] == 0} {
        ::glw::log "bindMouseWheel is not defined; wheel speed left alone"
        return
    }
    rename ::bindMouseWheel ::glw::coreBindMouseWheel

    proc ::bindMouseWheel {bindtag callback} {
        if {[string match *.glist $bindtag] && [string match *glist.ybar_* $callback]} {
            ::glw::bindWheel $bindtag
            return
        }
        ::glw::coreBindMouseWheel $bindtag $callback
    }
    ::glw::log "bindMouseWheel wrapped for *.glist"
}

# Game lists that exist before the plugin loads still get the new binding.
proc ::glw::rebindExisting {w} {
    set kids {}
    catch {set kids [winfo children $w]}
    foreach kid $kids {
        if {[string match *.glist $kid]} {
            ::glw::bindWheel $kid
            ::glw::log "rebound existing game list $kid"
        }
        ::glw::rebindExisting $kid
    }
}

proc ::glw::init {} {
    variable dir
    variable rows
    variable src
    variable logh

    catch {set logh [open [file join $dir glist_wheel.log] a]}
    ::glw::log "load start; dir=$dir"
    ::glw::resolveRows
    ::glw::log "rows per notch = $rows (from $src)"
    ::glw::wrap
    catch {::glw::rebindExisting .}
    ::glw::log "load done"
}

::glw::init
