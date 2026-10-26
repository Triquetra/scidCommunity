# Copyright (C) 2025-2026 Hugh Whelan
# SPDX-License-Identifier: GPL-2.0-or-later
#
# auto_comment_dialogs.tcl -- build the Auto Comment dialogs under real Tk.
#
#   wish tests/tcl/auto_comment_dialogs.tcl
#   xvfb-run -a wish tests/tcl/auto_comment_dialogs.tcl   (no display)
#
# The provider harness cannot see layout: it stubs Tk. This one creates the
# widgets and switches through every provider, which is what caught "none"
# matching no section at all and leaving the dialog with no body.
#
# The scid environment is stubbed; nothing here touches a database, an engine
# or the network. Window geometry is not asserted: the size a top-level ends up
# with is the window manager's business, and Wayland compositors ignore wm
# geometry entirely.

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
set ::savedCount 0
set ::saveResult 1
set ::messages {}
# The real options.write returns 1 when it wrote, 0 when it reported a failed
# open itself, and throws only if the write breaks part-way.
proc options.write {} {
    incr ::savedCount
    if {$::saveResult eq "error"} { error "disk full" }
    return $::saveResult
}
proc openURL {url} { set ::openedUrl $url }
proc tk_messageBox {args} { lappend ::messages [dict get $args -message] ; return ok }
set ::language E
set ::translatePieces 0

set root [file normalize [file join [file dirname [info script]] .. ..]]
source [file join $root tcl tools auto_comment.tcl]
source [file join $root tcl tools analysis_auto_comment.tcl]

proc visibleSections {w} {
    set out {}
    foreach n {note local openai opencode gemini deepseek} {
        set f $w.content.$n
        if {[winfo exists $f] && [winfo ismapped $f]} { lappend out $n }
    }
    return $out
}

# ------------------------------------------------------------ settings dialog --
puts "\n== settings dialog =="
::auto_comment::configureApiKey
update
set w .autoCommentConfig
check "dialog is built" [winfo exists $w]

foreach p {none local openai opencode gemini deepseek} {
    set ::auto_comment::provider $p
    if {[catch {::auto_comment::syncProviderSections $w} err]} {
        check "$p switches without a Tk error" 0 $err
        continue
    }
    update
    set expect [expr {$p eq "none" ? "note" : $p}]
    checkEq "$p shows its section" [visibleSections $w] [list $expect]
}

# the heading and the provider selector are always present
check "provider combo is always shown" [expr {[winfo ismapped $w.content.provider]}]
check "the dialog has a body below the selector" \
    [expr {[llength [visibleSections $w]] == 1}]

# switching through the combobox binding, not just by calling the proc
set ::auto_comment::provider none
::auto_comment::syncProviderSections $w
update
set ::auto_comment::provider opencode
event generate $w.content.provider <<ComboboxSelected>>
update
checkEq "combobox event switches sections" [visibleSections $w] {opencode}
check "opencode section has a key field" [expr {[winfo exists $w.content.opencode.key]}]
check "opencode section has a model field" [expr {[winfo exists $w.content.opencode.model]}]
check "opencode section offers models" \
    [expr {[llength [$w.content.opencode.model cget -values]] > 0}] \
    [$w.content.opencode.model cget -values]

# ------------------------------------ moving an existing setup to a channel --
# A user who has a Gemini key stored must be able to pick another provider
# without losing it: the provider list is the path, and the keys are per
# provider.
puts "\n== an existing Gemini setup can move to another channel =="
set ::auto_comment::provider gemini
set ::auto_comment::apiKey "stored-gemini-key"
set ::auto_comment::openaiKey ""
set ::auto_comment::openaiModel ""
::auto_comment::syncProviderSections $w
update
checkEq "it starts on the stored provider" [visibleSections $w] {gemini}

set ::auto_comment::provider openai
event generate $w.content.provider <<ComboboxSelected>>
update
checkEq "picking openai shows the openai section" [visibleSections $w] {openai}

set ::auto_comment::openaiUrl "https://api.deepseek.com"
set ::auto_comment::openaiKey "new-key"
set ::auto_comment::openaiModel "glm-5.3-flash"
set ::savedCount 0
set ::saveResult 1
::auto_comment::saveSettings $w
update
check "the dialog closed" [expr {![winfo exists $w]}]
checkEq "the provider that was saved is the new one" $::auto_comment::provider openai
checkEq "the Gemini key is still there" $::auto_comment::apiKey {stored-gemini-key}
checkEq "the new channel kept its own key" $::auto_comment::openaiKey {new-key}

# ---------------------------------------------------------------- saving ------
puts "\n== OK saves and closes =="
::auto_comment::configureApiKey
update
set ::auto_comment::provider opencode
set ::auto_comment::opencodeKey "secret"
set ::savedCount 0
set ::saveResult 1
::auto_comment::saveSettings $w
update
check "options.write ran" [expr {$::savedCount == 1}] "count $::savedCount"
check "the dialog closed" [expr {![winfo exists $w]}]

# A refused write must not take the typed key with it. options.write has
# already told the user, so the dialog adds nothing and stays open.
puts "\n== a failed save keeps the dialog and its values =="
::auto_comment::configureApiKey
update
set ::auto_comment::provider opencode
set ::auto_comment::opencodeKey "typed-but-unsaved"
set ::saveResult 0
set ::savedCount 0
set ::messages {}
::auto_comment::saveSettings $w
update
check "options.write was asked once" [expr {$::savedCount == 1}] "count $::savedCount"
check "the dialog stayed open" [winfo exists $w]
check "the key is still there" \
    [expr {$::auto_comment::opencodeKey eq "typed-but-unsaved"}] $::auto_comment::opencodeKey
check "no second complaint" [expr {[llength $::messages] == 0}] $::messages

# An unexpected error keeps it open too, and says why.
set ::saveResult "error"
set ::messages {}
::auto_comment::saveSettings $w
update
check "the dialog stayed open after an error" [winfo exists $w]
check "the user was told once" [expr {[llength $::messages] == 1}] $::messages
destroy $w

# ------------------------------------------------------------ batch dialog ----
puts "\n== Game Comment dialog =="
if {[catch {::analysis_auto_comment::batch_generate ""} err]} {
    check "batch dialog builds" 0 $err
} else {
    update
    set bw .analysisAutoCommentDlg
    check "batch dialog is built" [expr {[winfo exists $bw]}]
    check "it offers the same provider list" \
        [expr {[llength [$bw.content.provider cget -values]] == 6}] \
        [$bw.content.provider cget -values]

    set ::auto_comment::provider opencode
    ::auto_comment::syncModelCombo $bw.content.model
    checkEq "the model field follows the provider" \
        [$bw.content.model cget -textvariable] ::auto_comment::opencodeModel
    check "the opencode suggestions are listed" \
        [expr {[llength [$bw.content.model cget -values]] > 0}] \
        [$bw.content.model cget -values]

    set ::auto_comment::provider none
    ::auto_comment::syncModelCombo $bw.content.model
    checkEq "no model means an empty suggestion list" \
        [$bw.content.model cget -values] {}
    checkEq "and no model name is shown" [$bw.content.model get] {}

    set ::auto_comment::provider gemini
    ::auto_comment::syncModelCombo $bw.content.model
    checkEq "gemini still shows its own model" \
        [$bw.content.model get] $::auto_comment::model
    destroy $bw
}

puts "\n$checks checks, $fails failures"
exit [expr {$fails ? 1 : 0}]
