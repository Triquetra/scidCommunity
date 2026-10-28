# Copyright (C) 2026 David Crandall
# SPDX-License-Identifier: GPL-2.0-or-later
#
########################################################################
### Search limits that belong to an engine preset.
###
### An entry of ::engines(list) is a list:
###   0 name 1 cmd 2 args 3 dir 4 elo 5 time 6 url 7 uci 8 ucioptions 9 limits
### Element 9 is a dict {depth movetime autorun}. Entries loaded from a file
### written before element 9 existed have nine elements; an empty dict means
### "the preset says nothing about limits", and the legacy global settings
### (::enginewin::depth_limit / movetime_limit) still apply.

namespace eval enginelimits {}

# Grow a legacy entry to the current length. These are only ever written by
# ::enginecfg::write, so a short entry in memory is a file from an older
# version, not a corrupted one.
proc ::enginelimits::pad {enginecfg} {
    while {[llength $enginecfg] < 10} {
        lappend enginecfg {}
    }
    return $enginecfg
}

# The preset's limits as a dict, with the three keys always present.
proc ::enginelimits::of {enginecfg} {
    set lim [lindex [::enginelimits::pad $enginecfg] 9]
    if {[catch {dict size $lim}]} {
        set lim {}
    }
    return [dict merge {depth "" movetime "" autorun ""} $lim]
}

# True if value is an acceptable setting for key. An empty value always is:
# it means the limit is not set.
proc ::enginelimits::valid {key value} {
    if {$value eq ""} {
        return 1
    }
    if {![string is integer -strict $value] || $value < 1} {
        return 0
    }
    switch -- $key {
        depth    { return [expr {$value <= 500}] }
        movetime { return [expr {$value <= 3600000}] }
        autorun  { return [expr {$value <= 3600000}] }
    }
    return 0
}

# Return the entry with one limit changed. Throws on an unknown key or an
# out-of-range value, so a value typed into a spinbox cannot reach the file.
proc ::enginelimits::setLimit {enginecfg key value} {
    if {[lsearch -exact {depth movetime autorun} $key] < 0} {
        error "unknown engine limit: $key"
    }
    if {![::enginelimits::valid $key $value]} {
        error "invalid engine limit: $key $value"
    }
    set enginecfg [::enginelimits::pad $enginecfg]
    set lim [::enginelimits::of $enginecfg]
    dict set lim $key $value
    lset enginecfg 9 $lim
    return $enginecfg
}

# The Go message's limits list for a preset dict, in a fixed order.
proc ::enginelimits::goLimits {lim} {
    set lim [dict merge {depth "" movetime "" autorun ""} $lim]
    set out {}
    if {[dict get $lim depth] ne ""} {
        lappend out [list depth [dict get $lim depth]]
    }
    if {[dict get $lim movetime] ne ""} {
        lappend out [list movetime [dict get $lim movetime]]
    }
    return $out
}

# The limits to use for the named engine: its preset, with any key the preset
# leaves unset taken from fallback (the legacy global settings).
proc ::enginelimits::forName {name {fallback {}}} {
    set lim [dict merge {depth "" movetime "" autorun ""} $fallback]
    set enginecfg [::enginecfg::get $name]
    if {$enginecfg ne ""} {
        set preset [::enginelimits::of $enginecfg]
        dict for {key value} $preset {
            if {$value ne ""} {
                dict set lim $key $value
            }
        }
    }
    return $lim
}

# Store limits in the named engine's preset and save the engine list.
# Only the keys present in `lim` are changed: the window's depth/time editor
# does not touch autorun, and wiping a key it never showed would be data loss.
# An empty value means "not set" and is dropped, so the file carries only the
# limits the preset actually sets.
# Return true if an engine by that name exists.
proc ::enginelimits::saveFor {name lim} {
    set enginecfg [::enginecfg::get $name]
    if {$enginecfg eq ""} {
        return 0
    }
    set current [::enginelimits::of $enginecfg]
    foreach key {depth movetime autorun} {
        if {![dict exists $lim $key]} { continue }
        set value [dict get $lim $key]
        if {![::enginelimits::valid $key $value]} {
            error "invalid engine limit: $key $value"
        }
        dict set current $key $value
    }
    set out {}
    dict for {key value} $current {
        if {$value ne ""} { dict set out $key $value }
    }
    lset enginecfg 9 $out
    ::enginecfg::save $enginecfg
    return 1
}
