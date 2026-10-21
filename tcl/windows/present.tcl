# present.tcl: part of Scid
# Copyright (C) 2025-2026
#
# Presentation board: a board-only window that follows the main board, for
# showing a game on a projector or a second screen. The notation, engine and
# database windows stay on the presenter's screen.
#
# The board can be frozen (Ctrl+Shift+F): it then keeps the position it was
# showing while the game is navigated on the main board, so a variation or the
# solution of a puzzle can be examined without revealing it.

namespace eval ::windows::present {
    # The board-only window.
    variable win .presentWin

    # True while the window exists (the menu checkbutton's variable).
    variable isOpen 0

    # True while the window is frozen (the menu checkbutton's variable).
    variable frozen 0

    # True while the window is fullscreen.
    variable isFullscreen 0

    # Last window size handled by "resize" (to ignore pure move events).
    variable lastSize ""

    # Position currently on the presentation board. Kept so a flip or resize
    # can redraw it, frozen or not, including its last-move highlight.
    variable shownBoard ""
    variable shownMove ""
    variable shownNags ""

    # Geometry to restore when leaving fullscreen.
    variable savedGeometry ""
}

# ::windows::present::toggle --
#   Called from the menu checkbutton: open the window, or close it if it is
#   already open.
#
proc ::windows::present::toggle {} {
    if {[winfo exists $::windows::present::win]} {
        ::windows::present::close
    } else {
        ::windows::present::open
    }
}

# ::windows::present::open --
#   Creates the presentation window.
#
proc ::windows::present::open {} {
    variable win
    variable isOpen
    variable frozen
    variable isFullscreen
    variable lastSize
    variable shownBoard
    variable shownMove
    variable shownNags

    if {[winfo exists $win]} {
        raise $win
        return
    }

    toplevel $win
    wm title $win "scidCommunity: [tr WindowsPresentationBoard]"
    wm minsize $win 200 200
    wm protocol $win WM_DELETE_WINDOW ::windows::present::close
    # Neutral surround when the board does not fill the window (fullscreen).
    catch { $win configure -background black }

    # Start with the largest board that fits the screen: the audience should
    # be able to see it from a distance.
    ::board::new $win.board [::windows::present::maxBoardSize]
    ::board::showMarks $win.board 1
    if {[info exists ::boardCoords]} {
        catch { ::board::coords $win.board $::boardCoords }
    }
    pack $win.board -expand 1
    # The board adapts to the window (see ::windows::present::resize), which
    # also keeps it whole when a tiling window manager gives the window a
    # smaller area than the board's natural size.
    bind $win <Configure> { ::windows::present::resize }

    # Bindings on the toplevel reach every widget of the window. The board is
    # read-only: it has no move-entry bindings of its own.
    bind $win <Destroy> { if {[string equal %W .presentWin]} {
        ::windows::present::saveGeometry
        set ::windows::present::isOpen 0
        set ::windows::present::frozen 0
    } }
    bind $win <KeyPress-f> { ::windows::present::flip }
    bind $win <F11> { ::windows::present::fullscreen }
    bind $win <Escape> { ::windows::present::fullscreen 0 }
    bind $win <Control-Shift-F> { ::windows::present::toggleFreeze }
    bind $win <Control-Shift-W> { ::windows::present::close }

    set isOpen 1
    set frozen 0
    set isFullscreen 0
    set lastSize ""
    set shownBoard [sc_pos board]
    set shownMove [sc_game info previousMoveUCI]
    set shownNags [sc_pos getNags]
    ::windows::present::syncFlip

    ::windows::present::restoreGeometry
    ::windows::present::update
}

# ::windows::present::close --
#   Closes the presentation window and remembers its geometry.
#
proc ::windows::present::close {} {
    variable win
    variable isOpen
    variable frozen
    variable isFullscreen

    ::windows::present::saveGeometry
    if {[winfo exists $win]} { destroy $win }
    set isOpen 0
    set frozen 0
    set isFullscreen 0
}

# ::windows::present::update --
#   Called from the position-changed notification: makes the presentation
#   board show the current position and the marks of its comment.
#   Safe to call when the window is closed or frozen.
#
proc ::windows::present::update {} {
    variable win
    variable frozen
    variable shownBoard
    variable shownMove
    variable shownNags

    if {$frozen} { return }
    if {![winfo exists $win.board]} { return }
    set shownBoard [sc_pos board]
    set shownMove [sc_game info previousMoveUCI]
    set shownNags [sc_pos getNags]
    ::board::setmarks $win.board [sc_pos getComment]
    ::windows::present::redraw
}

# ::windows::present::redraw --
#   Draws $shownBoard with the last-move highlight. ::board::update only
#   draws that highlight for the main board, so a second board has to ask
#   for it; redrawing it here also keeps it correct after a flip or resize.
#
proc ::windows::present::redraw {} {
    variable win
    variable shownBoard
    variable shownMove
    variable shownNags

    if {![winfo exists $win.board]} { return }
    ::board::update $win.board $shownBoard
    ::board::lastMoveHighlight $win.board $shownMove $shownNags
}

# ::windows::present::resize --
#   Fits the board to the window. A tiling window manager can give the window
#   less space than the board's natural size; without this the board would be
#   clipped. Board sizes are discrete, so the largest one that fits is used.
#
proc ::windows::present::resize {} {
    variable win
    variable resizing
    variable lastSize
    variable shownBoard

    if {![winfo exists $win.board]} { return }
    # <Configure> also fires when the window only moves.
    set size "[winfo width $win]x[winfo height $win]"
    if {$size eq $lastSize} { return }
    # Resizing the canvas changes the toplevel size, which fires <Configure>
    # again: ignore the nested calls of one resize pass.
    if {[info exists resizing]} { return }
    set resizing 1
    after idle { unset -nocomplain ::windows::present::resizing }

    set lastSize $size
    ::update idletasks
    ::board::resizeAuto $win.board "0 0 [winfo width $win] [winfo height $win]"
    ::windows::present::redraw
}

# ::windows::present::syncFlip --
#   Brings the presentation board's orientation in line with the main board.
#   Called from ::board::flip whenever the main board is flipped (toolbar, the
#   "." key, the menu, or a game loaded with the FlipB flag). Flipping the
#   presentation board with "f" is a local override that lasts until the main
#   board is flipped again.
#
proc ::windows::present::syncFlip {} {
    variable win

    if {![winfo exists $win.board]} { return }
    set flipped [expr {[::board::isFlipped .main.board] ? 1 : 0}]
    if {[::board::isFlipped $win.board] == $flipped} { return }
    ::board::flip $win.board $flipped
    ::windows::present::redraw
}

# ::windows::present::flip --
#   Flips the presentation board alone, independently of the main board.
#
proc ::windows::present::flip {} {
    variable win
    if {![winfo exists $win.board]} { return }
    ::board::flip $win.board
    ::windows::present::redraw
}

# ::windows::present::fullscreen --
#   Toggles (or sets) fullscreen mode for the presentation window.
#   The window manager applies the change asynchronously, so the state is
#   tracked here instead of reading it back from "wm attributes".
#
proc ::windows::present::fullscreen {{value ""}} {
    variable win
    variable savedGeometry
    variable isFullscreen

    if {![winfo exists $win]} { return }
    if {$value eq ""} { set value [expr {!$isFullscreen}] }
    set value [expr {$value ? 1 : 0}]
    if {$value == $isFullscreen} { return }
    if {$value} { set savedGeometry [wm geometry $win] }
    if {[catch { wm attributes $win -fullscreen $value }]} { return }
    set isFullscreen $value
}

# ::windows::present::freeze --
#   Called from the menu checkbutton, which has already toggled $frozen.
#   When unfrozen the board catches up with the current position.
#
proc ::windows::present::freeze {} {
    variable frozen
    variable win

    if {![winfo exists $win]} {
        set frozen 0
        return
    }
    if {$frozen} {
        # Reply on the presenter's board only: the audience must not see this.
        ::board::setInfoAlert .main.board [tr WindowsPresentationBoard] \
            [tr PresentationFrozen] red "::windows::present::toggleFreeze"
    } else {
        ::windows::present::update
        catch { updateStatusBar }
    }
}

# ::windows::present::toggleFreeze --
#   Freezes or unfreezes the presentation board (keyboard shortcut).
#
proc ::windows::present::toggleFreeze {} {
    variable frozen
    variable win

    if {![winfo exists $win]} { return }
    set frozen [expr {!$frozen}]
    ::windows::present::freeze
}

# ::windows::present::maxBoardSize --
#   Largest board size that fits the screen: a board taller than the display
#   would be clipped, since the board has a fixed pixel size. The window can
#   still be moved to a larger projector screen, where it will not fill it.
#
proc ::windows::present::maxBoardSize {} {
    set limit [expr {int([winfo vrootheight .] * 0.92)}]
    set chosen $::boardSize
    if {[info exists ::boardSizes]} {
        foreach size $::boardSizes {
            # Board, coordinate labels and window borders.
            if {$size * 8 + 40 <= $limit} { set chosen $size }
        }
    }
    return $chosen
}

# ::windows::present::restoreGeometry --
#   Restores the saved geometry, kept on a visible screen: the projector or
#   second monitor may not be connected any more.
#
proc ::windows::present::restoreGeometry {} {
    variable win

    if {![info exists ::winGeometry($win)]} { return }
    set geom $::winGeometry($win)
    if {$geom eq "" || $geom eq "zoomed"} { return }

    if {[regexp {^(\d+)x(\d+)([+-]\d+)([+-]\d+)$} $geom -> w h x y]} {
        set sw [winfo vrootwidth $win]
        set sh [winfo vrootheight $win]
        set w [expr {min($w, $sw)}]
        set h [expr {min($h, $sh)}]
        set x [expr {max(0, min($x, $sw - $w))}]
        set y [expr {max(0, min($y, $sh - $h))}]
        set geom "${w}x${h}+${x}+${y}"
    }
    wm geometry $win $geom
}

# ::windows::present::saveGeometry --
#   Remembers the windowed geometry in options.dat. While the window is
#   fullscreen the geometry saved before going fullscreen is kept.
#
proc ::windows::present::saveGeometry {} {
    variable win
    variable savedGeometry
    variable isFullscreen

    if {![winfo exists $win]} { return }
    set geom ""
    if {$isFullscreen} {
        set geom $savedGeometry
    } elseif {[catch { wm geometry $win } geom]} {
        set geom ""
    }
    if {$geom ne ""} { set ::winGeometry($win) $geom }
}

# ----------------------------------------------------------------------
# End of file: present.tcl
# ----------------------------------------------------------------------
