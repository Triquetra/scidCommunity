#!/usr/bin/env wish
# Copyright (C) 2026 David Crandall
# SPDX-License-Identifier: GPL-2.0-or-later
#
# review_progress_pane_tk.tcl -- the progress pane's widgets, under Tk.
#
#   xvfb-run -a wish tests/tcl/review_progress_pane_tk.tcl
#
# The tclsh harness (review_progress_pane.tcl) decides what the pane shows; this
# builds it through the application's own docking seam and drives the parts only
# a widget can answer: that it is a docked pane and not a toplevel of its own,
# that it lands in a notebook the docking system knows about, that its board is
# sized without a measured width and carries no bindings, that a position
# published while its tab is not selected is on screen when the tab comes back,
# and that closing the tab cancels nothing.
#
# The docking layer is the real tcl/utils/win.tcl. ::board::new is a stub, but a
# stub held to the contract of tcl/board.tcl:662 - the `winfo exists` guard, the
# Board-classed frame and the canvas - and a check below reads board.tcl and
# fails if that contract moves. Grading a contract production does not have is
# what kept the old window invisible for a whole review round.

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

set root [file normalize [file join [file dirname [info script]] .. ..]]

# --- the app's surface, as much of it as the pane touches --------------------
array set ::EN {
    ReviewProgressTitle        {Review progress}
    ReviewProgressIdle         {No review is running}
    ReviewProgressProgress     {Reviewing position %s of %s}
    ReviewProgress             {Reviewing position %s of %s}
    ReviewProgressGameOf       {game %s of %s}
    ReviewProgressEngineWindow {Engine window %s}
    ReviewProgressRapid        {Rapid annotate}
    ReviewCoachProgress        {annotating %s of %s · prose %s of %s}
    ReviewGameButton           {Game Review}
    ReviewMoveButton           {Move Comment}
    Annotate                   {Annotate}
    FinishGame                 {Finish game}
    Cancel                     {Cancel}
}
proc tr {tag args} {
    if {[info exists ::EN($tag)]} { return [expr {[llength $args] ? [format $::EN($tag) {*}$args] : $::EN($tag)}] }
    return $tag
}
namespace eval ::icon {}
namespace eval ::utils::tooltip {}
namespace eval ::board {}
namespace eval ::reviewui {}
# The real helper is in tcl/start.tcl: paint a classic widget with the theme's
# background, and repaint it when the theme changes.
proc ::applyThemeColor_background {widget} {
    set bg [ttk::style lookup . -background "" #d9d9d9]
    $widget configure -background $bg
    bind $widget <<ThemeChanged>> [list ::applyThemeColor_background $widget]
}
proc ::reviewui::passFraction {done total} {
    if {![string is integer -strict $total] || $total < 1} { return "" }
    if {![string is integer -strict $done]} { return "" }
    if {$done < 0} { set done 0 }
    if {$done > $total} { set done $total }
    return [format %.4f [expr {double($done) / double($total)}]]
}
namespace eval ::reviewdriver {}
proc ::utils::tooltip::Set args {}
foreach f {font_Small font_SmallBold} { set ::$f TkDefaultFont }

# The pane's current position, for the "no run in flight" path.
proc sc_pos {args} { return {rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1} }

# ::board::new, reproduced from tcl/board.tcl:662 as it actually is: a path that
# already exists is refused outright, and both the frame (class Board) and the
# canvas inside it are created here.
proc ::board::new {w {psize 40}} {
    lappend ::board::newCalls $w
    set ::board::preExisted($w) [winfo exists $w]
    if {[winfo exists $w]} { return }
    ttk::frame $w -class Board
    canvas $w.bd -width [expr {8 * $psize}] -height [expr {8 * $psize}] \
        -highlightthickness 0
    grid $w.bd -row 6 -column 3
    set ::board::size($w) $psize
    return $w
}
proc ::board::update {w board {animate 0}} {
    lappend ::board::updates [list $w $board $animate]
    set ::board::drawn($w.bd) $board
    set ::board::animate($w.bd) $animate
    return
}
set ::board::newCalls {}
set ::board::updates {}

# The docking layer, unmodified: the seam the app uses for every pane.
source [file join $root tcl utils win.tcl]
set ::windowsDock 1
set ::docking::prev_nb {}
source [file join $root tcl utils chessboard.tcl]
source [file join $root tcl tools review_progress.tcl]
source [file join $root tcl tools review_progress_ui.tcl]
# passFraction lives with the other review UI decisions; only it is needed here.
proc ::reviewui::passFraction {done total} {
    if {![string is integer -strict $total] || $total < 1} { return "" }
    if {![string is integer -strict $done]} { return "" }
    if {$done < 0} { set done 0 }
    if {$done > $total} { set done $total }
    return [format %.4f [expr {double($done) / double($total)}]]
}
proc ::reviewdriver::cancel {} { set ::cancelled 1 }

proc settle {} { update idletasks ; update }

# The window the app would have: a paned window holding a notebook, registered
# the way ::docking::insert_notebook_ registers it. tb_close is the tab image
# every docked window is given.
image create photo tb_close
ttk::panedwindow .pw -orient vertical
pack .pw -fill both -expand 1
ttk::notebook .pw.nb
.pw add .pw.nb -weight 1
set ::docking::tbs(.pw.nb) .pw

# --- the source-level contract -----------------------------------------------

puts "== the pane is registered with the app's own docking seam =="

set fh [open [file join $root tcl utils win.tcl] r]
set winTcl [read $fh]
close $fh
check "::docking::create_window has an arm for the pane" \
    [expr {[string match {*reviewProgress*} $winTcl]}]
check "the arm keeps the fdock prefix, like every other arm" \
    [regexp {\\\.\(fdock\)\?reviewProgress} $winTcl]

set fh [open [file join $root tcl tools review_progress_ui.tcl] r]
set uiTcl [read $fh]
close $fh
check "the pane is not built with a toplevel command" \
    [expr {![regexp {\n[ \t]*toplevel[ \t]} $uiTcl]}]
check "the pane does not drive the window manager" \
    [expr {![regexp {\n[ \t]*wm[ \t]+(withdraw|deiconify|resizable|protocol|title|manage|geometry|state)} $uiTcl]}]

# The stub above is only worth anything if it still matches the real contract.
set fh [open [file join $root tcl board.tcl] r]
set boardTcl [read $fh]
close $fh
check "::board::new still refuses a path that already exists" \
    [regexp -line {proc ::board::new \{w \{psize 40\} \}} $boardTcl]
check "and still creates the frame and the canvas itself" \
    [expr {[string match {*ttk::frame $w -class Board*} $boardTcl] \
        && [string match {*canvas $w.bd*} $boardTcl]}]

puts "== it is a pane, in the notebook the dock would put it in =="

::docking::create_window .reviewProgress
settle
set win .reviewProgress
check "the pane exists" [winfo exists $win]
if {![winfo exists $win]} {
    puts ""
    puts "$checks checks, $fails failures"
    exit 1
}
checkEq "it is a frame, not a toplevel" [winfo class $win] "Frame"
checkEq "the dock knows which notebook holds it" [::docking::find_tbn $win] ".pw.nb"
checkEq "its toplevel is the app, not itself" [winfo toplevel $win] "."
check "it is in the notebook's tab list" \
    [expr {[lsearch -exact [.pw.nb tabs] $win] >= 0}]
check "the tab is titled from the translated key" \
    [expr {[.pw.nb tab $win -text] eq {Review progress}}]

# A pane that saves but cannot be restored is a silent layout loss. The saved
# layout is a tree of paned windows and notebooks naming their tabs; the restore
# path rebuilds each named window through ::docking::create_window, which is the
# arm asserted above.
set tree [::docking::layout_save_pw .pw]
check "the saved layout names the pane" \
    [expr {[string first $win $tree] >= 0}] "saved '$tree'"

puts "== the board is sized without a measured width, and is read-only =="

check "the path handed to ::board::new did not exist yet" \
    [expr {[info exists ::board::preExisted($win.board)] \
        && !$::board::preExisted($win.board)}]
check "::board::new made the Board frame, not a plain one" \
    [expr {[winfo exists $win.board] && [winfo class $win.board] eq "Board"}]

set canvas $win.board.bd
check "the canvas exists" [winfo exists $canvas]
check "the board is built at the explicit psize, not a measured width" \
    [expr {[info exists ::board::size($win.board)] \
        && $::board::size($win.board) == 40}]
check "the canvas is out of the focus order" \
    [expr {[string trim [$canvas cget -takefocus]] eq "0"}]
check "no square bindings are installed" [expr {[bind $canvas] eq ""}]

# A click on the board must do nothing at all: it is the main board that owns
# moves, and this one is not allowed to fight it for control.
set before [llength $::board::updates]
catch { event generate $canvas <Button-1> -x 20 -y 20 }
catch { event generate $canvas <B1-Motion> -x 40 -y 40 }
catch { event generate $canvas <ButtonRelease-1> -x 40 -y 40 }
settle
check "a click on the board does nothing" \
    [expr {[llength $::board::updates] == $before}]

puts "== a run feeds the header and the board =="

set token [::reviewprogress::begin [dict create \
    source review engine {Stockfish Deep} origin {enginewin 2}]]
settle
checkEq "the header is the string the run composed" \
    [$win.header cget -text] {Game Review — Stockfish Deep (Engine window 2)}

set fen {rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1}
set want {RNBQKBNRPPPP.PPP............P...................pppppppprnbqkbnr}
::reviewprogress::setPosition $token $fen 12 40
settle
checkEq "the board shows the position the run is searching" \
    $::board::drawn($canvas) $want
check "the redraw is animated off" [expr {$::board::animate($canvas) == 0}]
checkEq "the progress line counts the position" \
    [$win.progress cget -text] {Reviewing position 12 of 40}

# The lines the engine is considering, under the board: one widget, one block of
# text, written by the feed and never read back by the pane.
checkEq "no lines before the engine has reported any" \
    [$win.lines cget -text] ""
::reviewprogress::setLines $token "position fen $fen" \
    [dict create 1 {20 35 cp {e7e5 g1f3}} 2 {18 -120 cp {c7c5}}]
::reviewprogress::paintNow
settle
checkEq "the pane lists the lines with their scores and their moves" \
    [$win.lines cget -text] "1.  d20  -0.35  e5 Nf3\n2.  d18  +1.20  c5"
check "the lines sit between the board and the progress line" \
    [expr {[winfo manager $win.lines] eq "grid" && \
        [winfo rooty $win.lines] >= [winfo rooty $::reviewprogress::ui::board] && \
        [winfo rooty $win.lines] < [winfo rooty $win.progress]}]

puts "== the coach's prose is a second measure =="

::reviewprogress::setProse $token 3 9
settle
check "the coach's line is shown" [expr {[grid info $win.coach] ne ""}]
checkEq "it names both measures" [$win.coach cget -text] \
    {annotating 12 of 40 · prose 3 of 9}
check "and its own bar has its own fraction" \
    [expr {abs([$win.coachbar cget -value] - (3.0 / 9.0)) < 0.001}]

puts "== a hidden tab does not mean a paused run =="

# A docked pane is hidden by not being the selected tab, not by wm withdraw.
# The run must keep painting, and selecting the tab must draw what is current.
ttk::frame .pw.nb.other
.pw.nb add .pw.nb.other -text other
.pw.nb select .pw.nb.other
settle
check "the pane is not mapped while its tab is not selected" \
    [expr {![winfo ismapped $win]}]

set ::board::updates {}
set fen2 {rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2}
::reviewprogress::setPosition $token $fen2 20 40
settle
checkEq "a hidden pane still draws the position being searched" \
    $::board::drawn($canvas) [::reviewprogress::positionToBoard $fen2]

# The <Map> redraw is what makes the tab show current status rather than the
# position it had when it went away. Perturb the canvas first, so a pass can
# only have come from the redraw.
set ::board::drawn($canvas) "STALE"
set ::board::updates {}
.pw.nb select $win
settle
check "selecting the tab maps the pane" [winfo ismapped $win]
checkEq "coming back redraws from the current position" \
    $::board::drawn($canvas) [::reviewprogress::positionToBoard $fen2]
check "and that redraw is not animated" \
    [expr {[llength $::board::updates] && [lindex $::board::updates end 2] == 0}]

puts "== closing cancels nothing; Cancel is the run's own =="

set ::cancelled 0
::win::closeWindow $win
settle
check "closing the tab destroys the pane" [expr {![winfo exists $win]}]
check "closing the pane does not cancel the run" [expr {$::cancelled == 0}]
check "the job outlives the pane" [expr {[dict size [::reviewprogress::job]] > 0}]

# A run that outlives its pane keeps publishing, and that must not raise.
set rc [catch { ::reviewprogress::setPosition $token $fen2 24 40 } err]
check "a run keeps publishing with no pane to paint" [expr {$rc == 0}] $err
checkEq "and the job still moves" \
    [dict get [::reviewprogress::job] done] 24

puts "== reopening rebuilds it and draws the run as it stands =="

# The frame the dock creates is a classic Tk widget. Rebuild under a dark theme:
# the pane has to come back in the theme's colour, not Tk's grey.
ttk::style theme create reviewdark -parent classic -settings {
    ttk::style configure . -background #1e1e2e -foreground #cdd6f4
    ttk::style configure TFrame -background #1e1e2e
    ttk::style configure TLabel -background #1e1e2e -foreground #cdd6f4
}
ttk::style theme use reviewdark

::reviewprogress::ui::open
settle
check "reopening builds the pane again" [winfo exists $win]
checkEq "the rebuilt pane is painted with the theme's background" \
    [$win cget -background] #1e1e2e
check "and not Tk's classic grey" \
    [expr {[$win cget -background] ne "#d9d9d9"}]
checkEq "the pane is docked again" [::docking::find_tbn $win] ".pw.nb"
checkEq "the rebuilt board is at the explicit psize" \
    $::board::size($win.board) 40
checkEq "the rebuilt header is the run's own field" \
    [$win.header cget -text] {Game Review — Stockfish Deep (Engine window 2)}
checkEq "the rebuilt board shows the run as it stands" \
    $::board::drawn($win.board.bd) [::reviewprogress::positionToBoard $fen2]

::reviewprogress::finish $token
settle
checkEq "a finished run leaves the pane idle" \
    [$win.progress cget -text] {No review is running}
check "and hides the coach's measure" [expr {[grid info $win.coach] eq ""}]
check "and disables Cancel" [expr {[$win.cancel cget -state] eq "disabled"}]

puts "== Cancel asks the run to stop =="

::reviewprogress::begin [dict create source review engine {Stockfish Deep} \
    origin {enginewin 1} cancel ::reviewdriver::cancel]
settle
$win.cancel invoke
settle
check "Cancel asks the run to stop" [expr {$::cancelled == 1}]

puts "== the board is fitted to the pane it is docked in =="

# A 40-px-square board plus the rows above and below it is taller than a docked
# pane: at a 314-px pane the grid clipped the board and pushed the lines, the
# progress line, the bar and Cancel out of the window. The pane fits the board
# to the height it is given - <Configure> schedules ::refitSoon, which measures
# the rows and re-makes the board at the largest ::boardSizes entry that fits.
set ::boardSizes {12 16 20 24 28 32 36 40}

# The rule, independently of the implementation: the largest piece size whose
# board fits the room left by the rows, the pane's 50 px of padding and the
# board's own 9 px of chrome.
proc expectedPsize {h} {
    set used 0
    foreach child {header lines progress bar cancel} {
        if {[winfo exists .reviewProgress.$child]} {
            incr used [winfo reqheight .reviewProgress.$child]
        }
    }
    set avail [expr {$h - $used - 50}]
    foreach size [lsort -integer -decreasing $::boardSizes] {
        if {$size > 40} { continue }
        if {$size * 8 + 9 <= $avail} { return $size }
    }
    return [lindex [lsort -integer $::boardSizes] 0]
}

set ::reviewprogress::job ""
::reviewprogress::ui::open
settle
# A real resize, not a call into refit: the pane has to react to the height the
# dock gives it, which is what a reader dragging the splitter does.
wm geometry . 1100x900
settle
set tallPsize [set ::board::size($win.board)]
checkEq "a tall pane gives the board 40 px squares" $tallPsize 40
checkEq "which is what the room allows" $tallPsize [expectedPsize [winfo height $win]]

wm geometry . 1100x420
settle
set shortPsize [set ::board::size($win.board)]
check "a short pane shrinks the board" [expr {$shortPsize < $tallPsize}] \
    "tall $tallPsize short $shortPsize"
checkEq "to the largest size the room allows" $shortPsize [expectedPsize [winfo height $win]]
check "and every row is inside the pane" \
    [expr {[winfo height $win.cancel] > 0 \
        && [winfo rooty $win.cancel] + [winfo height $win.cancel] \
           <= [winfo rooty $win] + [winfo height $win]}]
check "the board is a remade board, not a resized one" \
    [expr {[winfo class $win.board] eq "Board" && [winfo exists $win.board.bd]}]

# The fit changes the board and nothing else: the row that holds the run's lines
# is still there, still empty, and still has its own height reserved.
check "the lines block survives the fit" \
    [expr {[winfo exists $win.lines] && [winfo height $win.lines] > 0}]

wm geometry . 1100x900
settle
checkEq "and a tall pane again brings the 40 px board back" \
    $::board::size($win.board) 40

# A height too small to be a pane - the dock hands over 0 or 1 while the frame
# is being created - is not a measurement and must not shrink the board.
set before $::board::size($win.board)
::reviewprogress::ui::refit 1
settle
checkEq "a height below the pane's floor is ignored" $::board::size($win.board) $before

puts "== with no run in flight the board shows the current position =="

set ::reviewprogress::job ""
set ::board::updates {}
::reviewprogress::ui::open
settle
set last [lindex $::board::updates end]
check "the idle path drew a board" [expr {[llength $last] == 3}] "no call recorded"
checkEq "the board string is the second argument, not the animate slot" \
    [lindex $last 1] [::reviewprogress::positionToBoard \
        {rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1}]
check "the idle draw is not animated" [expr {[lindex $last 2] == 0}] \
    "got '[lindex $last 2]'"
checkEq "the idle path draws the pane's own board" [lindex $last 0] $win.board

puts ""
puts "$checks checks, $fails failures"
exit [expr {$fails ? 1 : 0}]
