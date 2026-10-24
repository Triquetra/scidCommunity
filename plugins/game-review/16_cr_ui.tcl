# cr_ui.tcl -- menus, progress, report and settings for the review plugin.
# Loading this file is also what registers the plugin.

namespace eval ::cr_ui {
    variable prog ""
    variable rep ""
    variable dir [file dirname [info script]]
}

# ------------------------------------------------------------------- menus --
proc ::cr_ui::log {msg} {
    catch {
        set f [file join $::cr_ui::dir cr_load.log]
        set fp [open $f a]
        puts $fp "[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}] $msg"
        close $fp
    }
}

proc ::cr_ui::installMenus {} {
    set parent .menu.tools
    if {![winfo exists $parent]} {
        ::cr_ui::log "no .menu.tools; falling back to .menu"
        set parent .menu
    }
    # A cascade is tidier, a flat command is harder to lose: try the cascade,
    # fall back to three plain items, and log which one was used.
    set m $parent.review
    if {![catch {
        destroy $m
        menu $m -tearoff 0
        $m add command -label "Game review" -command ::cr_review::startSafe
        $m add command -label "What's the threat?" -command ::cr_llm::threatSafe
        $m add separator
        $m add command -label "Review settings..." -command ::cr_ui::settingsSafe
        $parent add cascade -label "Game review" -menu $m
    }]} {
        ::cr_ui::log "menu: cascade added under $parent"
        return
    }
    catch {
        $parent add separator
        $parent add command -label "Game review" -command ::cr_review::startSafe
        $parent add command -label "What's the threat?" -command ::cr_llm::threatSafe
        $parent add command -label "Review: settings..." -command ::cr_ui::settingsSafe
        ::cr_ui::log "menu: flat items added under $parent"
    }
}

# ---------------------------------------------------------------- progress --
proc ::cr_ui::progressOpen {total {subtitle ""}} {
    variable prog
    set ::cr_ui::startMs [clock milliseconds]
    set ::cr_ui::total $total
    if {[winfo exists .crProgress]} { destroy .crProgress }
    set w .crProgress
    toplevel $w
    wm title $w "Game review"
    wm transient $w .
    wm resizable $w 0 0
    wm title $w [expr {$subtitle eq "" ? "Game review" : "Game review - $subtitle"}]
    ttk::label $w.msg -text "Analysing..." -anchor w
    ttk::progressbar $w.bar -mode determinate -maximum [expr {$total > 0 ? $total : 1}] -length 320
    ttk::button $w.cancel -text "Cancel" -command {
        set ::cr_review::cancel 1
        catch { ::engineNoWin::closeEngine 20 }
        catch { ::engineNoWin::closeEngine 21 }
        destroy .crProgress
    }
    pack $w.msg -fill x -padx 10 -pady {10 2}
    pack $w.bar -fill x -padx 10 -pady 2
    pack $w.cancel -anchor e -padx 10 -pady {2 10}
    set prog $w
}

proc ::cr_ui::fmtClock {ms} {
    set sec [expr {int($ms / 1000)}]
    return [format "%d:%02d" [expr {$sec / 60}] [expr {$sec % 60}]]
}

proc ::cr_ui::progressSet {done total msg} {
    if {![winfo exists .crProgress]} return
    set text "$msg $done/$total"
    if {[info exists ::cr_ui::startMs]} {
        set elapsed [expr {[clock milliseconds] - $::cr_ui::startMs}]
        append text "  -  [::cr_ui::fmtClock $elapsed] elapsed"
        if {$done > 0 && $total > $done} {
            set eta [expr {int($elapsed * ($total - $done) / $done)}]
            append text ", ~[::cr_ui::fmtClock $eta] left"
        }
    }
    catch { .crProgress.msg configure -text $text }
    catch {
        .crProgress.bar configure -maximum [expr {$total > 0 ? $total : 1}] -value $done
    }
    update idletasks
}

proc ::cr_ui::progressClose {} {
    catch { destroy .crProgress }
}

# ------------------------------------------------------------------ report --
proc ::cr_ui::reportOpen {} {
    variable rep
    set w .crReport
    catch { destroy $w }
    toplevel $w
    wm title $w "Game review"
    wm geometry $w 620x420
    set rep $w
    ttk::frame $w.head
    ttk::label $w.head.t -text "Game review" -font TkHeadingFont
    ttk::button $w.head.close -text "Close" -command [list destroy $w]
    pack $w.head.t -side left -padx 6 -pady 4
    pack $w.head.close -side right -padx 6 -pady 4
    pack $w.head -fill x

    text $w.txt -wrap word -height 20 -width 70 -padx 8 -pady 6
    pack $w.txt -fill both -expand 1 -padx 6 -pady 4
    $w.txt insert end [::cr_review::reportText]
    $w.txt configure -state disabled

    ttk::label $w.note -text "" -anchor w -foreground gray40
    pack $w.note -fill x -padx 8
    ttk::button $w.jump -text "Jump to next key moment" -command ::cr_ui::jumpNext
    pack $w.jump -anchor w -padx 8 -pady {0 8}
    set ::cr_ui::jumpIdx -1
    return $w
}

proc ::cr_ui::jumpNext {} {
    set kms $::cr_review::R(keyMoments)
    if {![llength $kms]} return
    incr ::cr_ui::jumpIdx
    if {$::cr_ui::jumpIdx >= [llength $kms]} { set ::cr_ui::jumpIdx 0 }
    set k [lindex $kms $::cr_ui::jumpIdx]
    catch { sc_move ply [dict get $k ply] }
    catch { ::notify::PosChanged }
}

proc ::cr_ui::proseProgress {done total} {
    if {[winfo exists .crReport]} {
        catch { .crReport.note configure -text "Coach: $done/$total" }
    }
    update idletasks
}

proc ::cr_ui::proseNote {msg} {
    if {[winfo exists .crReport]} {
        catch { .crReport.note configure -text $msg }
    }
}

# ---------------------------------------------------------------- settings --
# Menu entry point: a Tcl error inside a dialog builder leaves an empty
# toplevel behind and nothing else, so catch, log and show it instead.
proc ::cr_ui::settingsSafe {} {
    if {[catch { ::cr_ui::settings } err]} {
        catch { ::cr_ui::log "settings dialog failed: $err" }
        catch { destroy .crSettings }
        tk_messageBox -icon warning -title "scidCommunity" \
            -message "Could not open the review settings:\n\n$err"
    }
}


# Save with just enough validation to keep a typo from breaking the pipeline:
# depth must be a whole number, and there is no upper bound.
proc ::cr_ui::settingsCommit {} {
    set d [string trim $::cr_settings::s(depth)]
    if {![string is integer -strict $d] || $d < 1} {
        catch { tk_messageBox -icon warning -title "Game review" -parent .crSettings \
            -message "Depth must be a whole number, 1 or more. Higher depths take longer." }
        return 0
    }
    set ::cr_settings::s(depth) $d
    ::cr_settings::save
    return 1
}

proc ::cr_ui::settings {} {
    set w .crSettings
    catch { destroy $w }
    toplevel $w
    wm title $w "Game review settings"
    wm transient $w .
    ttk::frame $w.f -padding 10
    pack $w.f -fill both -expand 1

    set names {}
    catch { set names [lsort [::enginecfg::names]] }

    ttk::label $w.f.l1 -text "Analysis engine" -anchor w
    ttk::combobox $w.f.e1 -values $names -textvariable ::cr_settings::s(engine_analysis) -state readonly -width 34
    ttk::label $w.f.l2 -text "Verifier engine (must differ)" -anchor w
    ttk::combobox $w.f.e2 -values $names -textvariable ::cr_settings::s(engine_verify) -state readonly -width 34
    ttk::label $w.f.l3 -text "Depth (no maximum - higher is slower)" -anchor w
    # deliberately an entry, not a spinbox: there is no ceiling worth enforcing
    # here. A depth past what the engine reaches just runs longer and reports
    # its own achieved depth.
    ttk::entry $w.f.d -textvariable ::cr_settings::s(depth) -width 6
    ttk::label $w.f.lt1 -text "Engine threads (8 = physical cores)" -anchor w
    ttk::spinbox $w.f.th -from 1 -to 32 -textvariable ::cr_settings::s(threads) -width 5
    ttk::label $w.f.lt2 -text "Hash MB per engine" -anchor w
    ttk::spinbox $w.f.ha -from 16 -to 8192 -increment 128 -textvariable ::cr_settings::s(hash_mb) -width 6
    ttk::label $w.f.lp -text "Best line in comment (plies, 0 = off)" -anchor w
    ttk::spinbox $w.f.pv -from 0 -to 12 -textvariable ::cr_settings::s(pv_moves) -width 5
    ttk::checkbutton $w.f.pvv -text "Best line as a variation (else in the comment)" \
        -variable ::cr_settings::s(pv_variation)
    ttk::checkbutton $w.f.sb -text "Skip engine analysis of book plies" \
        -variable ::cr_settings::s(skip_book)
    ttk::label $w.f.lb1 -text "Book detection" -anchor w
    ttk::combobox $w.f.bm -values {eco plies} -textvariable ::cr_settings::s(book_mode) -state readonly -width 12
    ttk::label $w.f.lb2 -text "Book plies (fallback / plies mode)" -anchor w
    ttk::spinbox $w.f.bp -from 0 -to 30 -textvariable ::cr_settings::s(book_plies) -width 5
    ttk::label $w.f.l4 -text "Verification" -anchor w
    ttk::combobox $w.f.v -values {candidates all off} -textvariable ::cr_settings::s(verify_mode) -state readonly -width 12

    ttk::checkbutton $w.f.ca -text "Comment on Best/Excellent/Good/Book too" -variable ::cr_settings::s(comment_all)
    ttk::checkbutton $w.f.we -text "Write \[%eval\] tokens for the score graph" -variable ::cr_settings::s(write_eval)
    ttk::checkbutton $w.f.le -text "Use the coach (LLM)" -variable ::cr_settings::s(llm_enabled)
    ttk::checkbutton $w.f.pp -text "Phase paragraphs in the report" -variable ::cr_settings::s(phase_prose)

    ttk::label $w.f.l5 -text "Ollama endpoint" -anchor w
    ttk::entry $w.f.u -textvariable ::cr_settings::s(api_url) -width 34
    ttk::label $w.f.l6 -text "API key (Ollama Cloud)" -anchor w
    ttk::entry $w.f.k -textvariable ::cr_settings::s(api_key) -width 34 -show "*"
    ttk::label $w.f.l7 -text "Model" -anchor w
    ttk::entry $w.f.m -textvariable ::cr_settings::s(model) -width 34
    ttk::label $w.f.l8 -text "Opponent RD (100 = established rating)" -anchor w
    ttk::spinbox $w.f.rd -from 30 -to 350 -textvariable ::cr_settings::s(opponent_rd) -width 5

    set r 0
    foreach wdg [list $w.f.l1 $w.f.e1 $w.f.l2 $w.f.e2 $w.f.l3 $w.f.d \
                      $w.f.lt1 $w.f.th $w.f.lt2 $w.f.ha $w.f.lp $w.f.pv $w.f.pvv $w.f.sb \
                      $w.f.lb1 $w.f.bm $w.f.lb2 $w.f.bp $w.f.l4 $w.f.v \
                      $w.f.ca $w.f.we $w.f.l5 $w.f.u $w.f.l6 $w.f.k $w.f.l7 $w.f.m \
                      $w.f.l8 $w.f.rd $w.f.le] {
        grid $wdg -row $r -column 0 -sticky w -pady 2
        incr r
    }

    ttk::button $w.f.save -text "Save" -command {
        if {[::cr_ui::settingsCommit]} { destroy .crSettings }
    }
    ttk::button $w.f.cancel -text "Cancel" -command { destroy .crSettings }
    grid $w.f.save -row $r -column 0 -sticky w -pady {8 0}
    incr r
    grid $w.f.cancel -row $r -column 0 -sticky w -pady 2
}

# ------------------------------------------------------------------- boot --
catch { ::cr_ui::log "plugin load start; scidUserDir=[expr {[info exists ::scidUserDir] ? $::scidUserDir : "?"}]" }
if {[catch { ::cr_settings::load } err]} { catch { ::cr_ui::log "settings load failed: $err" } }
::cr_ui::installMenus
catch { ::cr_ui::log "plugin load done; enginecfg=[expr {[llength [info commands ::enginecfg::names]] ? "yes" : "no"}]" }
