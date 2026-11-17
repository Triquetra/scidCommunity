# Copyright (C) 2026 Hugh Whelan
# SPDX-License-Identifier: GPL-2.0-or-later
#
# review_settings_dialog.tcl -- build the Review Settings dialog under real Tk.
#
#   wish tests/tcl/review_settings_dialog.tcl
#   xvfb-run -a wish tests/tcl/review_settings_dialog.tcl   (no display)
#
# The tclsh harnesses cannot see this: ::reviewui decides what the dialog
# stores, but ::enginewin::reviewSettings makes the widgets, and a body it
# cannot compile leaves a half-built window. That is exactly what happened -
# one bracket short in the var_lines trace, so the rows appeared and the OK and
# Cancel buttons never did, and no setting could be applied at all.
#
# The scid environment is stubbed; nothing here touches a database, an engine or
# the network. Geometry is not asserted: window size is the window manager's
# business.

set fails 0
set checks 0
proc check {label cond {detail ""}} {
    incr ::checks
    if {$cond} {
        puts "  ok   $label"
    } else {
        incr ::fails
        if {$detail eq ""} { puts "  FAIL $label" } else { puts "  FAIL $label -- $detail" }
    }
}
proc checkEq {label got want} {
    check $label [expr {$got eq $want}] "got '$got' want '$want'"
}

# --------------------------------------------------------------- environment --
proc options.store {varname {default ""}} {
    if {![info exists $varname]} { set $varname $default }
}
proc options.write {} { return 1 }
proc openURL {url} {}
proc tk_messageBox {args} { return ok }
proc tr {tag args} {
    # The format strings the labels are built from, as english.tcl carries them.
    if {[info exists ::TR($tag)]} { return $::TR($tag) }
    if {[llength $args]} { return [lindex $args 0] }
    return $tag
}
array set ::TR {
    ReviewFromPreset {%s (from engine preset)}
    ReviewMovetime    {Time cap (ms)}
    ReviewCoachSettings {Coach settings...}
}
proc ::button_image {args} { return "" }
# The real helper is in tcl/start.tcl: paint a classic widget with the theme's
# background, and repaint it when the theme changes.
proc ::applyThemeColor_background {widget} {
    set bg [ttk::style lookup . -background "" #d9d9d9]
    $widget configure -background $bg
    bind $widget <<ThemeChanged>> [list ::applyThemeColor_background $widget]
}
namespace eval ::utils::tooltip {}
proc ::utils::tooltip::Set {args} {}
namespace eval ::board {}
proc ::board::update {args} {}
proc ::board::setmarks {args} {}
namespace eval ::pgn {}
proc ::pgn::Refresh {args} {}
namespace eval ::win {}
proc ::win::add {args} {}
namespace eval ::enginecfg {}
# What the window's preset lookup answers. The window is pointed at a preset, and
# that preset is where the pass's Lines, Depth and time cap come from: the dialog
# shows them read-only, so this is what those rows read.
set ::engineCfgAnswer {Stockfish /usr/bin/stockfish {} {} 0 0 {} 1 \
    {{MultiPV 3 spin 1 1 10}} {depth 30 movetime 900}}
set ::enginewin_lastengine(1) Stockfish
proc ::enginecfg::get {name} { return $::engineCfgAnswer }
# Coach settings are the Game Comment settings dialog. It is a dialog of its own,
# and building one is all this harness needs from it.
namespace eval ::auto_comment {}
set ::autoOpened 0
proc ::auto_comment::openSettings {args} {
    incr ::autoOpened
    toplevel .autoCommentConfig
}
set ::language E
set ::translatePieces 0

set root [file normalize [file join [file dirname [info script]] .. ..]]
set ::scidTclDir [file join $root tcl]
set ::scidShareDir $root
set ::scidVersion test
set ::scidName Scid
set ::initialdir $root
set ::showGameInfo 0
set ::language E
set ::initialdir $root

source [file join $root tcl tools score_seed.tcl]
source [file join $root tcl tools move_labels.tcl]
source [file join $root tcl tools engine_limits.tcl]
source [file join $root tcl tools comment_colors.tcl]
source [file join $root tcl tools game_review.tcl]
source [file join $root tcl tools review_ui.tcl]
source [file join $root tcl windows engine.tcl]

wm withdraw .
toplevel .engineWin1

# ----------------------------------------------------------------- the dialog --
puts "\nthe Review Settings dialog"

::review::reset
set ::enginewin::pgnviewer(1) 0
set w ""
set rc [catch { set w [::enginewin::reviewSettings 1] } err]
checkEq "the dialog is built without an error" $rc 0
checkEq "and it is the window the button names" $w .engineWin1.reviewSettings

# The half-built window this harness was written for: the rows were there and
# the buttons were not, because the body stopped compiling mid-proc.
check "the OK button exists" [winfo exists $w.b.ok]
check "the Cancel button exists" [winfo exists $w.b.cancel]
foreach key {var_lines var_cp move_comment_wait diagram \
        opening_errors opening_window tactical_exercises coach cloud_eval} {
    check "the $key row is there" [winfo exists $w.f.v$key]
}
# Lines, Depth and the time cap are the engine preset's now: the dialog has no row
# for them, and the read-only note under the fields is where they appear.
foreach gone {mpv depth movetime} {
    check "the $gone row is gone" [expr {![winfo exists $w.f.v$gone]}]
}
check "the dialog says where the pass's numbers come from" \
    [expr {[winfo exists $w.f.preset] && [$w.f.preset cget -text] ne ""}]
# An on/off setting is a checkbox, not a number box that holds 0 or 1: the value
# a user edits here is a switch, and a spinbox beside "Coach prose" offers "2".
foreach key {move_comment_wait diagram opening_errors tactical_exercises coach cloud_eval} {
    checkEq "the $key row is a checkbox" [winfo class $w.f.v$key] TCheckbutton
}
checkEq "a number row is still a number box" [winfo class $w.f.vvar_lines] TSpinbox
checkEq "the coach row opens on the stored switch" \
    $::enginewin::reviewsetting(1,coach) 0
# The cloud pre-pass is on unless the user turned it off, and the row says so.
checkEq "the cloud pre-pass row opens on" \
    $::enginewin::reviewsetting(1,cloud_eval) 1

# The coach's provider, key and model are the Game Comment settings dialog; the
# way there belongs beside the switch rather than behind a menu the user has to
# find. The nested dialog is a real dialog, so this window must not hold a grab:
# a grab here swallows every event meant for its child, and the child - dropdowns
# included - comes up and cannot be clicked. The stub's ::auto_comment::openSettings
# builds a window of its own, as the real one does.
puts "\nthe coach settings button and the nested dialog"
check "the coach settings button is there" [winfo exists $w.f.coachsettings]
checkEq "and it is the window's own label" [$w.f.coachsettings cget -text] {Coach settings...}
checkEq "Review Settings holds no grab over its child dialog" [grab current] ""
$w.f.coachsettings invoke
checkEq "Coach settings opens from Review Settings" $::autoOpened 1
check "in a window of its own" [winfo exists .autoCommentConfig]
checkEq "and pressing it did not close Review Settings" [winfo exists $w] 1
destroy .autoCommentConfig
checkEq "it opens on the stored values" \
    [list $::enginewin::reviewsetting(1,var_lines) \
          $::enginewin::reviewsetting(1,var_cp)] {1 0}

# What the user does: type the numbers, press OK.
puts "\ntyping a value and pressing OK"
set ::enginewin::reviewsetting(1,var_lines) 2
set ::enginewin::reviewsetting(1,var_cp) 40
$w.b.ok invoke
checkEq "the dialog is gone" [winfo exists $w] 0
checkEq "var_lines is stored" $::reviewopt(var_lines) 2
checkEq "and so is var_cp" $::reviewopt(var_cp) 40
# A fresh start reads the saved option, which is what the next session sees.
set ::review::S [dict create]
checkEq "and a fresh start reads it back" [::review::get var_lines] 2

# A refusal keeps the dialog and the values the user can still correct.
puts "\na refused value keeps the dialog open"
::review::setValue mpv 3
set w2 [::enginewin::reviewSettings 1]
set ::enginewin::reviewsetting(1,var_lines) 9
$w2.b.ok invoke
checkEq "the dialog stays open" [winfo exists $w2] 1
check "the reason is shown" [expr {$::enginewin::reviewwhy(1) ne ""}]
checkEq "and the setting is not changed" [::review::get var_lines] 2
destroy $w2

# The variation box's ceiling is the preset's MultiPV, resolved when the dialog
# opens: there is no lines box beside it any more for it to follow.
puts "\nthe variation box follows the preset's MultiPV"
set ::engineCfgAnswer {Stockfish /usr/bin/stockfish {} {} 0 0 {} 1 {{MultiPV 4 spin 1 1 10}} {}}
set w3 [::enginewin::reviewSettings 1]
checkEq "its ceiling is the preset's MultiPV" [$w3.f.vvar_lines cget -to] 4
destroy $w3
set ::engineCfgAnswer {}

# The time cap is the preset's now, with no row of its own: the read-only note
# under the fields is where the pass's cap (with its depth and lines) appears.
puts "\nthe preset's numbers, read-only"
set ::engineCfgAnswer {Stockfish /usr/bin/stockfish {} {} 0 0 {} 1 {{MultiPV 3 spin 1 1 10}} {depth 30 movetime 900}}
set w5 [::enginewin::reviewSettings 1]
check "the read-only note is there" [winfo exists $w5.f.preset]
checkEq "and names the pass's lines, depth and cap" \
    [$w5.f.preset cget -text] \
    {Lines 3, Depth 30, Time cap (ms): 900 (from engine preset)}
checkEq "with no cap row to edit" [winfo exists $w5.f.vmovetime] 0
destroy $w5
set ::engineCfgAnswer {}

# The coach row opens on what was stored, and turning it on is stored by OK like
# any other setting on this dialog.
puts "\nthe coach switch is stored"
set w6 [::enginewin::reviewSettings 1]
checkEq "it opens off" $::enginewin::reviewsetting(1,coach) 0
set ::enginewin::reviewsetting(1,coach) 1
$w6.b.ok invoke
checkEq "the dialog is gone" [winfo exists $w6] 0
checkEq "OK stores the coach switch" $::reviewopt(coach) 1
set ::review::S [dict create]
checkEq "and a fresh start reads it back" [::review::get coach] 1
::review::setValue coach 0

# The opening-errors finder's window is the old dialog's 10-20, default 12, and
# the two new switches are off until the user saves them on.
puts "\nthe opening finder and the exercise switch are saved"
set w7 [::enginewin::reviewSettings 1]
checkEq "the opening finder opens off" \
    $::enginewin::reviewsetting(1,opening_errors) 0
checkEq "the exercise switch opens off" \
    $::enginewin::reviewsetting(1,tactical_exercises) 0
checkEq "the window opens on the old default" \
    $::enginewin::reviewsetting(1,opening_window) 12
set ::enginewin::reviewsetting(1,opening_errors) 1
set ::enginewin::reviewsetting(1,tactical_exercises) 1
set ::enginewin::reviewsetting(1,opening_window) 15
$w7.b.ok invoke
checkEq "OK stores the opening finder" $::reviewopt(opening_errors) 1
checkEq "OK stores the exercise switch" $::reviewopt(tactical_exercises) 1
checkEq "OK stores the window" $::reviewopt(opening_window) 15
set ::review::S [dict create]
checkEq "and a fresh start reads the finder back" [::review::get opening_errors] 1
checkEq "the exercise switch too" [::review::get tactical_exercises] 1
checkEq "and the window" [::review::get opening_window] 15

# A hand-edited value must not open the dialog outside the range the setter
# accepts; the setter refuses and keeps the old value.
checkEq "a window below the old range is refused" \
    [::review::setValue opening_window 9] {opening_window must be 10..20}
checkEq "a window above it too" \
    [::review::setValue opening_window 21] {opening_window must be 10..20}
checkEq "the stored window survives the refusals" [::review::get opening_window] 15
::review::setValue opening_errors 0
::review::setValue tactical_exercises 0
::review::setValue opening_window 12

# A toplevel is a classic Tk widget and keeps Tk's grey; the ttk rows inside
# follow the theme, so the strip beside OK/Cancel is the only place the old
# colour showed through.
puts "\nthe window follows the theme"

ttk::style theme create reviewdark -parent classic -settings {
    ttk::style configure . -background #1e1e2e -foreground #cdd6f4
    ttk::style configure TFrame -background #1e1e2e
    ttk::style configure TLabel -background #1e1e2e -foreground #cdd6f4
}
ttk::style theme use reviewdark
set w4 [::enginewin::reviewSettings 1]
checkEq "the dialog is painted with the theme's background" \
    [$w4 cget -background] #1e1e2e
check "and not Tk's classic grey" \
    [expr {[$w4 cget -background] ne "#d9d9d9"}]
destroy $w4

puts "\n$checks checks, $fails failures"
exit [expr {$fails ? 1 : 0}]
