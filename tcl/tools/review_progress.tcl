# Copyright (C) 2026 David Crandall
# SPDX-License-Identifier: GPL-2.0-or-later
#
# review_progress.tcl -- what a review progress board shows, without Tk.
#
# A review runs on its own engine connection and never touches the board: the
# reader can walk the game, open another one, or do nothing at all while it
# works. The progress board is the window onto that work, and it is fed a
# position as a FEN and nothing else. It has no game, no cursor and no clock, so
# it cannot move the user's board and cannot fight it for control - which is the
# whole point of it existing rather than the review drawing on the main board.
#
# Everything a widget would otherwise have to decide is here, where tclsh can
# reach it: the FEN-to-board-string feed, the header each source composes, and
# the job the window draws from. tcl/tools/review_progress_ui.tcl keeps the
# widgets and reads nothing but the job.

namespace eval ::reviewprogress {
    # The run the board is showing, or "" when nothing is running. One board,
    # one run: a second run started while the first is in flight takes the
    # board, because it is decoration over a run and the newest run is the one
    # the reader asked for.
    variable job ""
    variable seq 0
    # The window's draw hook, as {*}$painter <job>. Empty in tclsh, which is
    # what makes this file sourceable without Tk.
    variable painter ""
    # A repaint scheduled by the live-lines feed (see ::reviewprogress::setLines).
    variable paintTimer ""
    # The position a spec was last replayed to, so the feed that names the
    # engine's lines does not replay twenty moves for every PV it is handed.
    variable lastSpec ""
    variable lastPos ""
    # SAN renderings of lines already named, keyed by position and PV: an engine
    # repeats the same PV at every depth it finishes.
    variable sanMemo
    array set sanMemo {}
}

# The position the board draws, as ::board::update wants it: 64 characters,
# index 0 = a1, upper case white, lower case black, "." for an empty square.
#
# A FEN the parser refuses answers "": a stray frame of the wrong position is
# worse than a stale one, and the run keeps its last good board.
proc ::reviewprogress::positionToBoard {fen} {
    if {[string trim $fen] eq ""} { return "" }
    if {[catch { set pos [::chessboard::fromFen $fen] }]} { return "" }
    set out ""
    foreach square [dict get $pos board] {
        if {$square eq ""} { append out "." } else { append out $square }
    }
    if {[string length $out] != 64} { return "" }
    return $out
}

# The FEN a driver spec searches FROM: everything after `fen` up to `moves`, or
# the whole string when it is a bare FEN. `position startpos` has no FEN and
# answers "".
#
# This exists because the FEN is a multi-word field: `lindex ... 3` reads the
# side to move, not the FEN, and a job whose `fen` field is not a FEN is a trap
# for the next reader of the job dict.
proc ::reviewprogress::specFen {spec} {
    set words [regexp -all -inline {\S+} [string trim $spec]]
    set at [lsearch -exact $words fen]
    # A bare FEN is the whole spec: no `fen` keyword to find, and treating it as
    # "no fen" would empty the field for exactly the callers that pass one.
    # `position startpos ...` really has no FEN, and answers "".
    if {$at < 0} {
        if {[lindex $words 0] eq "position"} { return "" }
        return [string trim $spec]
    }
    set rest [lrange $words [expr {$at + 1}] end]
    set m [lsearch -exact $rest moves]
    if {$m >= 0} { set rest [lrange $rest 0 [expr {$m - 1}]] }
    return [join $rest " "]
}

# A position a pass searches, as ::reviewdriver hands it to the engine:
# "position fen <fen> moves <m1> <m2> ...", or a bare FEN. The FEN alone is the
# position before the moves, so the moves are replayed on the pure board rather
# than on the game: the board the reader is looking at is not this pass's.
proc ::reviewprogress::specToBoard {spec} {
    set pos [::reviewprogress::specPos $spec]
    if {$pos eq ""} { return "" }
    set out ""
    foreach square [dict get $pos board] {
        if {$square eq ""} { append out "." } else { append out $square }
    }
    if {[string length $out] != 64} { return "" }
    return $out
}

# The position a spec searches, as a ::chessboard position dict, or "" when the
# spec cannot be followed.
#
# One-entry memo: the live-lines feed asks for the same position many times a
# second while a search runs, and replaying a forty-move line for every PV it
# reports is work nobody sees. A move list the pure board cannot play is not a
# position: the FEN's own, which is still where the search started.
proc ::reviewprogress::specPos {spec} {
    variable lastSpec
    variable lastPos
    set spec [string trim $spec]
    if {$spec eq ""} { return "" }
    if {$spec eq $lastSpec} { return $lastPos }
    set words [regexp -all -inline {\S+} $spec]
    set fen ""
    set moves {}
    set at [lsearch -exact $words fen]
    if {$at >= 0} {
        set rest [lrange $words [expr {$at + 1}] end]
        set m [lsearch -exact $rest moves]
        if {$m >= 0} {
            set fen [join [lrange $rest 0 [expr {$m - 1}]] " "]
            set moves [lrange $rest [expr {$m + 1}] end]
        } else {
            set fen [join $rest " "]
        }
    } elseif {[lindex $words 0] eq "position" && [lindex $words 1] eq "startpos"} {
        # A standard game's map carries "position startpos moves ..." rather
        # than a FEN. It is a position like any other: start from the standard
        # array and replay the moves. Without this the board string was empty,
        # ::reviewprogress::setSpec returned before recording its counts, and a
        # live review left the pane on its header with a still board and bar.
        set fen {rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1}
        set m [lsearch -exact $words moves]
        if {$m >= 0} { set moves [lrange $words [expr {$m + 1}] end] }
    } else {
        set fen $spec
    }
    set pos ""
    if {[llength $moves]} {
        catch {
            set p [::chessboard::fromFen $fen]
            foreach uci $moves { set p [::chessboard::makeMove $p $uci] }
            set pos $p
        }
    }
    if {$pos eq ""} { catch { set pos [::chessboard::fromFen $fen] } }
    set lastSpec $spec
    set lastPos $pos
    return $pos
}

# The source, as a reader names it. The tokens are the runs, not the windows:
# two windows can run the same Game Review, and the header says which run.
proc ::reviewprogress::sourceLabel {source} {
    switch -- $source {
        review      { return [tr ReviewGameButton] }
        movecomment { return [tr ReviewMoveButton] }
        annotate    { return [tr Annotate] }
        rapid       { return [tr ReviewProgressRapid] }
        finish      { return [tr FinishGame] }
        default     { return $source }
    }
}

# Where the run came from, as {kind index}: the engine window that asked. The
# pane origin the classic Finish Game and the annotate pass used went with the
# Analysis window (#437 §5). Composed here rather than at draw time, because the
# window may have been closed by the time the board repaints.
proc ::reviewprogress::originText {spec} {
    if {![llength $spec]} { return "" }
    lassign $spec kind n
    switch -- $kind {
        enginewin    { return [format [tr ReviewProgressEngineWindow] $n] }
        default      { return [lindex $spec 0] }
    }
}

# The header, composed once where the run starts and carried in the job as a
# field. A lookup at draw time could name the engine of a window the user has
# since pointed elsewhere - the one thing a header must never do.
#
#   <source> — <engine> (<origin>) · game <n> of <total>
#
# Every part after the source is optional: a run whose preset was deleted keeps
# its name if it had one and shows only what it knows if it did not.
proc ::reviewprogress::header {fields} {
    set source ""
    catch { set source [dict get $fields source] }
    set out [::reviewprogress::sourceLabel $source]
    set engine ""
    catch { set engine [dict get $fields engine] }
    if {$engine ne ""} { append out " \u2014 $engine" }
    set origin ""
    catch { set origin [dict get $fields origin] }
    if {[llength $origin]} { set origin [::reviewprogress::originText $origin] }
    if {$origin ne ""} { append out " ($origin)" }
    set game ""
    set total ""
    catch { set game [dict get $fields game] }
    catch { set total [dict get $fields total] }
    if {$game ne "" && $total ne ""} {
        append out " \u00b7 " [format [tr ReviewProgressGameOf] $game $total]
    }
    return $out
}

# The window's draw hook. Empty in tclsh: a run with no window open still
# records its job, and the window picks it up when it is opened.
proc ::reviewprogress::setPainter {cmd} {
    variable painter
    set painter $cmd
    return
}

proc ::reviewprogress::paint {} {
    variable job
    variable painter
    if {$painter eq ""} { return }
    # An empty job is painted too: the window has to hear that a run ended and
    # fall back to saying so, rather than freezing on the last position.
    # A painter that raises must not take the run down with it: the board is
    # decoration over a job, not a party to it.
    catch { {*}$painter $job }
    return
}

# A run has started. `fields` are the header's fields (source, engine, origin,
# and for a batch run game and total); the token is what the run publishes
# against, so a late reply from a run that has already ended is ignored.
proc ::reviewprogress::begin {fields} {
    variable job
    variable seq
    incr seq
    set token "progress$seq"
    set game ""
    set total ""
    catch { set game [dict get $fields game] }
    catch { set total [dict get $fields total] }
    # The run's own stop, for the pane's Cancel. It is a field like the header:
    # the pane serves every run, and only the owner of a run may stop it.
    set cancel ""
    catch { set cancel [dict get $fields cancel] }
    set job [dict create token $token \
        header [::reviewprogress::header $fields] \
        source [expr {[dict exists $fields source] ? [dict get $fields source] : ""}] \
        fields $fields cancel $cancel \
        board "" fen "" ply "" done "" total "" game $game totalGames $total \
        lines {} linesRaw {} coachDone "" coachTotal ""]
    ::reviewprogress::paint
    return $token
}

# The coach's queue, after the search. Its counts are a second measure rather
# than a replacement: the search bar is full by then, and the prose bar says how
# much of the model work is left. A late reply for a run the pane has moved on
# from is ignored, like every other feed.
proc ::reviewprogress::setProse {token done total} {
    variable job
    if {![dict size $job] || [dict get $job token] ne $token} { return 0 }
    if {![string is integer -strict $done] || ![string is integer -strict $total]} {
        return 0
    }
    if {$total < 1} { return 0 }
    dict set job coachDone $done
    dict set job coachTotal $total
    ::reviewprogress::paint
    return 1
}

proc ::reviewprogress::job {} {
    variable job
    return $job
}

# The header is a field, but a batch's game number is part of it and the game
# changes. Recomposing it from the fields the run began with keeps the promise
# the design makes: the header never looks anything up at draw time, so a
# covered window redrawn later still names the engine and pane the run started
# with, while the number follows the game in flight.
proc ::reviewprogress::rehead {job} {
    if {![dict exists $job fields]} { return $job }
    set fields [dict get $job fields]
    dict set fields game [dict get $job game]
    dict set fields total [dict get $job total]
    dict set job fields $fields
    dict set job header [::reviewprogress::header $fields]
    return $job
}

# The position the run is searching now. `done`/`total` are the run's search
# counts when it has them; a batch run also passes the game it is on, so the
# header's game number moves with the run rather than at the next begin.
#
# Returns 1 when the board changed, 0 when the position was refused or the
# token is not the run the board is showing.
proc ::reviewprogress::setPosition {token fen {done ""} {total ""} {game ""}} {
    variable job
    if {![dict size $job] || [dict get $job token] ne $token} { return 0 }
    set board [::reviewprogress::positionToBoard $fen]
    if {$board eq ""} { return 0 }
    # The lines are NOT cleared here: a pass at depth 12 changes position more
    # than ten times a second, and a block blanked at every change is a block
    # that is empty whenever the reader looks at it. They are replaced by the
    # new position's first report, and ::reviewprogress::clearLines is what a
    # finished run uses.
    dict set job fen $fen
    dict set job board $board
    if {$done ne ""} { dict set job done $done }
    if {$total ne ""} { dict set job total $total }
    if {$game ne ""} { dict set job game $game }
    set job [::reviewprogress::rehead $job]
    ::reviewprogress::paint
    return 1
}

# The position a pass is searching, from the spec the driver queued. Same
# contract as setPosition, with the moves in the spec replayed on the pure
# board so the board shows where the search actually is.
proc ::reviewprogress::setSpec {token spec {done ""} {total ""} {game ""}} {
    variable job
    if {![dict size $job] || [dict get $job token] ne $token} { return 0 }
    set board [::reviewprogress::specToBoard $spec]
    if {$board eq ""} { return 0 }
    # The lines stay until the new position reports its own (see setPosition):
    # clearing them here blanked the block for most of a fast pass.
    dict set job fen [::reviewprogress::specFen $spec]
    dict set job board $board
    catch { dict set job spec $spec }
    if {$done ne ""} { dict set job done $done }
    if {$total ne ""} { dict set job total $total }
    if {$game ne ""} { dict set job game $game }
    set job [::reviewprogress::rehead $job]
    ::reviewprogress::paint
    return 1
}

# The engine's own lines for the position the run is on, as the driver collects
# them: MultiPV index -> {depth score type pv}. This is what the pass is
# considering, not a summary of it - the reader asked to see the lines and their
# scores while the review works, and without them a pass that is waiting for a
# depth looks like a program that has stopped.
#
# The feed is called from inside the engine's own reply, once per PV line, so it
# does the cheap part here (a comparison, the SAN of at most a few short lines)
# and leaves the repaint to one scheduled tick. A dict that has not changed is
# not repainted at all.
proc ::reviewprogress::setLines {token spec lines} {
    variable job
    if {![dict size $job] || [dict get $job token] ne $token} { return 0 }
    set raw [dict create]
    catch { set raw $lines }
    set same 0
    catch { set same [expr {[dict get $job linesRaw] eq $raw}] }
    if {$same} { return 0 }
    dict set job linesRaw $raw
    dict set job lines [::reviewprogress::formatLines \
        [::reviewprogress::specPos $spec] $raw]
    ::reviewprogress::paintSoon
    return 1
}

# One rendered line: the MultiPV index, the depth it was reported at, its score
# and the moves.
#
# The score is White's, which is what the analysis window shows with its default
# `scoreside`; the engine reports the side to move's, so a Black-to-move position
# flips. A mate keeps the engine's own "+M4" / "-M4" spelling. Eight plies is
# enough to see the idea and short enough to name three lines inside one frame.
proc ::reviewprogress::formatLines {pos lines {plies 8}} {
    if {$pos eq ""} { return {} }
    set keys [dict keys $lines]
    if {![llength $keys]} { return {} }
    set flip [expr {[dict get $pos side] eq "b"}]
    set fen ""
    catch { set fen [::chessboard::toFen $pos] }
    set out {}
    foreach idx [lsort -integer $keys] {
        lassign [dict get $lines $idx] depth score type pv
        set cells [list "$idx."]
        if {[string is integer -strict $depth] && $depth > 0} {
            lappend cells "d$depth"
        }
        set scoreStr [::reviewprogress::scoreText $score $type $flip]
        if {$scoreStr ne ""} { lappend cells $scoreStr }
        set san [::reviewprogress::sanOf $fen $pos $pv $plies]
        if {[llength $san]} { lappend cells [join $san " "] }
        lappend out [join $cells "  "]
    }
    return $out
}

# The SAN of one PV, memoised on the position it is played from.
#
# Naming a line costs a legal-move list per ply, and an engine reports the same
# PV again at every depth it finishes - each iteration is a new score on the same
# moves. The memo makes the names free after the first report; it is small and
# thrown away whole when it grows, because there is nothing in it worth keeping
# across a review.
proc ::reviewprogress::sanOf {fen pos pv {plies 8}} {
    variable sanMemo
    set key "$fen|[join $pv { }]"
    if {[info exists sanMemo($key)]} { return $sanMemo($key) }
    set san [::chessboard::sanLine $pos $pv $plies]
    if {[array size sanMemo] > 96} { catch { array unset sanMemo } }
    set sanMemo($key) $san
    return $san
}

# An engine score as text: centipawns to a signed two-place number, a mate as the
# engine's own distance with its sign. "" when there is no score to show.
proc ::reviewprogress::scoreText {score type {flip 0}} {
    if {![string is integer -strict $score]} { return "" }
    if {$flip} { set score [expr {-$score}] }
    if {$type eq "mate"} {
        if {$score >= 0} { return "+M$score" }
        return "-M[expr {abs($score)}]"
    }
    return [format "%+.2f" [expr {$score / 100.0}]]
}

# The repaint the lines feed schedules. The driver calls it from inside an engine
# reply, and a pane that redraws its board for every PV line would spend the
# search's own time on decoration; one tick is enough for the eye.
proc ::reviewprogress::paintSoon {} {
    variable paintTimer
    if {$paintTimer ne ""} { return }
    set paintTimer [after 200 [list ::reviewprogress::paintNow]]
    return
}

proc ::reviewprogress::paintNow {} {
    variable paintTimer
    set paintTimer ""
    ::reviewprogress::paint
    return
}

# Nothing more is coming: a queued repaint has nothing to show.
proc ::reviewprogress::paintCancel {} {
    variable paintTimer
    if {$paintTimer eq ""} { return }
    catch { after cancel $paintTimer }
    set paintTimer ""
    return
}
# The progress line under the board. A run that has not searched yet says so
# rather than showing 0 of 0.
proc ::reviewprogress::progressText {job} {
    set done ""
    set total ""
    catch { set done [dict get $job done] }
    catch { set total [dict get $job total] }
    if {$done eq "" || $total eq ""} { return [tr ReviewProgressIdle] }
    return [format [tr ReviewProgress] $done $total]
}

# The run is over: nothing to show. The window stays open and says so, because
# closing it would be the run's decision and the run has none to make.
proc ::reviewprogress::finish {token} {
    variable job
    if {![dict size $job] || [dict get $job token] ne $token} { return 0 }
    ::reviewprogress::paintCancel
    set job ""
    ::reviewprogress::paint
    return 1
}

# Write a collected continuation into a game, once.
#
#   game   the game index to write, or "" / "0" for the game that is open
#   moves  the UCI moves to append at the end of the main line
#   note   an optional comment for the final position (a tablebase result)
#
# Returns "" when the moves landed, or the reason nothing was written.
#
# Nothing here paints. Tcl only paints when the event loop runs, so a commit
# that calls no `update`, no `updateBoard`, no `::notify::PosChanged` and no
# `::board::update` is atomic on screen however long it takes: the reader never
# sees the borrowed game. That is the whole of the rule, and it is why a run
# that writes a game the reader is not looking at can borrow one at all (the
# idiom at tcl/game.tcl:65: push a copy, load, edit, save, pop).
#
# A refused move undoes what it had written and pops the borrow; a cancelled
# run never reaches here, because the collect phase does not touch the game.
proc ::reviewprogress::commitMoves {game moves {note ""}} {
    if {![llength $moves] && $note eq ""} { return "" }
    set out ""
    set borrowed 0
    set marked 0
    if {[catch {
        if {$game ne "" && $game ne "0"} {
            sc_game push copy
            sc_game load $game
            set borrowed 1
        }
        # One restore point for the whole commit: a move the game refuses half
        # way through must not leave the line half extended.
        catch { undoFeature save ; set marked 1 }
        set cursor [::review::cursorSave]
        sc_move end
        foreach uci $moves {
            if {[::ucifmt::sc_move_add $uci]} {
                set out "the move $uci was rejected"
                break
            }
        }
        if {$out eq "" && $note ne ""} {
            catch {
                sc_pos setComment [::review::mergeComment \
                    [sc_pos getComment] $note]
            }
        }
        if {$out eq "" && $borrowed} { sc_game save $game }
        if {$out ne "" && $marked} { catch { undoFeature undo } }
        # Same discipline as ::review::writeMove: a restore that could not find
        # its line leaves a known position, and only -1 needs the start.
        set restored 1
        if {[catch { set restored [::review::cursorRestore $cursor] }]} {
            set restored 1
        }
        if {$restored < 0} { catch { sc_move ply 0 } }
    } err]} {
        set out $err
        if {$marked} { catch { undoFeature undo } }
    }
    if {$borrowed} { catch { sc_game pop } }
    return $out
}
