# Copyright (C) 2026 David Crandall
# SPDX-License-Identifier: GPL-2.0-or-later
#
# review_ui.tcl -- the engine window's two review buttons, without Tk.
#
# Game Review and Move Comment are two buttons over one engine pass. What they
# do is decided here, where it can be tested from tclsh: which of them is live,
# which positions a pass searches, what the settings dialog holds and what it
# stores. tcl/windows/engine.tcl keeps the widgets, and every call into it is
# guarded so a missing widget or engine is a no-op rather than an error in the
# middle of a game.
#
# Nothing here searches and nothing here touches the board.

namespace eval ::reviewui {}

# The positions a pass searches, as the {ply positionSpec} pairs
# ::reviewdriver::start takes.
#
# The arithmetic - which positions, and the one after the last move - belongs to
# ::review::searchPlies; the main line, with its null-move headers, belongs to
# ::review::mainLineMap. This only reads the map, so the board never moves to
# build a position. A position the map cannot name is dropped: an empty spec is
# a Go with no position in it.
#
# ::reviewdriver::positions has this exact contract and belongs to the driver
# card (kanban t_41770d0a); when that lands it is used instead of this copy.
proc ::reviewui::positions {map plies bookEnd} {
    if {[llength [info commands ::reviewdriver::positions]]} {
        return [::reviewdriver::positions $map $plies $bookEnd]
    }
    return [::reviewui::specs $map [::review::searchPlies $plies $bookEnd]]
}

# The same mapping for a list of positions the caller already has: Move Comment
# searches the position before a move and the one after it, which is not a plan
# ::review::searchPlies produces.
proc ::reviewui::specs {map indexes} {
    set out {}
    foreach ply $indexes {
        if {[catch { set spec [dict get [dict get $map positions] $ply] }]} {
            continue
        }
        if {[string trim $spec] eq ""} { continue }
        lappend out [list $ply $spec]
    }
    return $out
}

# Which of the window's three review controls are live, from the state the
# window is in. Nothing here reads a widget or asks the engine: the caller
# passes what it knows, so this is the whole decision and it is testable.
#
#   game   plies in the open game (0: no game, or an empty one)
#   engine the analysis engine's name ("" when none is selected)
#   pass   "" , or the pass state: searching, writing
#   move   the UCI move played from the current position ("" at the end)
#
# A pass owns its own engine connection, but it owns the window's buttons too:
# starting a second pass over a running one is a Go with no engine behind it.
# Cancel is the way out, so it is live exactly while a pass is.
#
# `reason` is not shown to the user - a disabled button keeps its tooltip - but
# it is what a bug report needs, and it is what the tests assert.
proc ::reviewui::buttons {state} {
    set game [expr {[dict exists $state game] ? [dict get $state game] : 0}]
    set engine [expr {[dict exists $state engine] ? [dict get $state engine] : ""}]
    set pass [expr {[dict exists $state pass] ? [dict get $state pass] : ""}]
    set move [expr {[dict exists $state move] ? [dict get $state move] : ""}]
    set out [dict create review disabled movecomment disabled cancel disabled reason ""]
    if {$pass ne ""} {
        dict set out cancel normal
        dict set out reason {pass running}
        return $out
    }
    if {![string is integer -strict $game] || $game < 1} {
        dict set out reason {no game}
        return $out
    }
    if {$engine eq ""} {
        dict set out reason {no engine}
        return $out
    }
    dict set out review normal
    # No move after the current position is nothing for Move Comment to label.
    # It is not a reason against the review, which covers the whole line.
    if {$move ne ""} { dict set out movecomment normal }
    return $out
}

# The settings the dialog owns, in the order it applies them.
#
# Threads and Hash are deliberately absent: they are properties of the engine
# preset (#382), set from the window's own controls, and a review dialog that
# also wrote them would be a second place to get them wrong. The order matters
# because ::review::setValue has cross-field rules - mpv caps var_lines - so a
# single edit that lowers both must apply mpv first.
variable ::reviewui::SETTING_KEYS {mpv depth var_lines var_cp move_comment_wait}

# The review setting a dialog row edits, and the label it shows. `Lines` and
# `Depth` are the keys the engine window already uses for the same two numbers.
variable ::reviewui::SETTING_LABELS {
    mpv               Lines
    depth             Depth
    var_lines         ReviewVarLines
    var_cp            ReviewVarCp
    move_comment_wait ReviewMoveWait
}

proc ::reviewui::settingKeys {} {
    variable ::reviewui::SETTING_KEYS
    return $::reviewui::SETTING_KEYS
}

proc ::reviewui::settingLabel {key} {
    variable ::reviewui::SETTING_LABELS
    if {![dict exists $::reviewui::SETTING_LABELS $key]} { return "" }
    return [::reviewui::tr [dict get $::reviewui::SETTING_LABELS $key]]
}

# What the dialog opens with.
proc ::reviewui::settings {} {
    set out [dict create]
    foreach key [::reviewui::settingKeys] {
        dict set out $key [::review::get $key]
    }
    return $out
}

# Store what the dialog holds. Every field is offered to ::review::setValue,
# which owns the rules; a refusal is collected and the next field is still
# tried, because the user pressed OK once and losing the four good fields to
# the one bad one is worse than showing them the refusal. Returns the reasons,
# in dialog order; "" means the whole edit landed.
proc ::reviewui::applySettings {values} {
    set why {}
    foreach key [::reviewui::settingKeys] {
        if {![dict exists $values $key]} { continue }
        set reason [::review::setValue $key [dict get $values $key]]
        if {$reason ne ""} { lappend why $reason }
    }
    return $why
}

# Threads and Hash as the preset advertises them, for the dialog's read-only
# line: "Threads 8, Hash 256 MB". Empty when the engine advertises neither,
# which is an engines.dat written before ::enginelimits existed.
proc ::reviewui::presetLimits {enginecfg} {
    set d [::review::engineDefaults $enginecfg]
    set parts {}
    if {[dict get $d threads] ne ""} { lappend parts "Threads [dict get $d threads]" }
    if {[dict get $d hash] ne ""} { lappend parts "Hash [dict get $d hash] MB" }
    return [join $parts ", "]
}

# The read-only line itself. "" when the preset carries nothing to show, so the
# dialog can leave the row out rather than showing an empty claim.
proc ::reviewui::presetNote {enginecfg} {
    set limits [::reviewui::presetLimits $enginecfg]
    if {$limits eq ""} { return "" }
    return [format [::reviewui::tr ReviewFromPreset] $limits]
}

# The translation table, or the key itself when there is none: a tclsh test has
# no language files, and a missing translation must not be an error on a button.
proc ::reviewui::tr {key} {
    # Fully qualified: an unqualified `info commands tr` finds this very proc,
    # because it runs inside ::reviewui.
    if {[llength [info commands ::tr]] == 0} { return $key }
    return [::tr $key]
}

# A user-visible string this module owns: a button's text, a tooltip, a title.
proc ::reviewui::label {key} {
    return [::reviewui::tr $key]
}

# What Move Comment does from the current analysis depth.
#
#   {action now}          write with what the engine has
#   {action wait depth N} wait until the analysis reaches N
#
# ::review::moveCommentPlan owns the rule (it is ::review's setting and its
# depth); this only turns "now, or the depth to wait for" into a dict the window
# can branch on without re-parsing a number that is either "now" or a depth.
proc ::reviewui::moveCommentStatus {depth_now} {
    set plan [::review::moveCommentPlan $depth_now]
    if {[string equal $plan now]} {
        return [dict create action now depth ""]
    }
    return [dict create action wait depth $plan]
}

# The status line for that decision: "" once the comment can be written.
proc ::reviewui::moveCommentMessage {depth_now} {
    set st [::reviewui::moveCommentStatus $depth_now]
    if {[dict get $st action] eq "now"} { return "" }
    return [format [::reviewui::tr ReviewWaitForDepth] [dict get $st depth]]
}

# The status line while a pass runs. "" when there is nothing to report, so the
# window can clear the label rather than show "position 0 of 0".
proc ::reviewui::progressText {done total} {
    if {![string is integer -strict $total] || $total < 1} { return "" }
    return [format [::reviewui::tr ReviewProgress] $done $total]
}

# And the status line when it ends badly: the reason is the driver's or the
# board's own words, and swallowing it leaves the user with a pass that did
# nothing and said nothing.
proc ::reviewui::failedText {reason} {
    if {$reason eq ""} { return "" }
    return [format [::reviewui::tr ReviewFailed] $reason]
}

# The depth a one-move comment searches at, and whether anything has to wait.
#
# With move_comment_wait on (the default) the comment has to be the one a review
# would have written, so a shallow analysis is not good enough and the pass
# searches at the review's depth. With it off the window's own analysis is the
# answer whenever it has a number at all: that is what "write whatever the engine
# has now" means, and re-searching it at 18 would be doing the work twice.
proc ::reviewui::moveCommentDepth {depth_now} {
    set target [::review::get depth]
    set st [::reviewui::moveCommentStatus $depth_now]
    if {[dict get $st action] eq "now"} {
        set depth $target
        if {[string is integer -strict $depth_now]} { set depth $depth_now }
        return [dict create depth $depth wait 0]
    }
    return [dict create depth $target wait 1]
}

# The bounds a dialog spin box offers. They agree with ::review::setValue, which
# is still the authority: a value the box should never have offered is refused
# and reported rather than silently clamped. var_cp has no upper bound in the
# setter; 500 is where a variation margin stops being a filter and starts being
# "write no variations at all".
variable ::reviewui::SETTING_RANGES {
    mpv               {1 5}
    depth             {6 60}
    var_lines         {0 5}
    var_cp            {0 500}
    move_comment_wait {0 1}
}

proc ::reviewui::settingRange {key} {
    variable ::reviewui::SETTING_RANGES
    if {![dict exists $::reviewui::SETTING_RANGES $key]} { return "" }
    set range [dict get $::reviewui::SETTING_RANGES $key]
    # var_lines is capped by mpv, so its box has to follow mpv or it offers a
    # number the setter refuses. mpv 1 means no alternatives at all, and then the
    # only value the setter takes is 0.
    if {$key eq "var_lines"} {
        set mpv [::review::get mpv]
        set hi [expr {$mpv < 2 ? 0 : $mpv}]
        return [list [lindex $range 0] $hi]
    }
    return $range
}

# The thread and hash values the dialog shows read-only, for a caller that wants
# them as a pair rather than as the one line presetNote builds.
proc ::reviewui::presetValues {enginecfg} {
    return [::review::engineDefaults $enginecfg]
}
