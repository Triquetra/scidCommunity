# cr_review.tcl -- review pipeline: gather the game, run the engine pass,
# classify every ply, write annotations, and build the report text.
#
# Depends on scid's Tcl API (sc_game / sc_move / sc_pos) and on scid's engine
# layer through cr_engine.tcl. Classification itself is pure (cr_classify.tcl).

namespace eval ::cr_review {
    variable R
    array set R {}

    # label -> NAG symbol written into the PGN. Best/Excellent/Good/Book have
    # no move-quality NAG; the [Label] comment carries them.
    variable NAG
    array set NAG {
        brilliant !!  great !  inaccuracy ?!  mistake ?  miss ?  blunder ??
    }
    variable LABEL
    array set LABEL {
        brilliant Brilliant great Great best Best excellent Excellent good Good
        book Book forced Forced inaccuracy Inaccuracy mistake Mistake miss Miss
        blunder Blunder
    }
}

proc ::cr_review::log {msg} {
    catch { ::cr_ui::log "review: $msg" }
}

# Menu entry point. Every stage is logged to cr_load.log and any error is
# shown: a Tcl error here would otherwise be invisible in a GUI build.
proc ::cr_review::startSafe {} {
    ::cr_review::log "menu invoked"
    if {[catch { ::cr_review::start } err]} {
        ::cr_review::log "FAILED: $err"
        catch { ::cr_ui::progressClose }
        tk_messageBox -icon warning -title "scidCommunity" \
            -message "Game review could not run:\n\n$err"
    }
}

# Which plies are opening theory, and where the engine pass should start.
# Preferred source is the opening book itself (sc_book): a book is keyed on the
# position, so a game that wanders out of theory and transposes back is judged
# per ply instead of by a single boundary. Falls back to the ECO probe, then to
# a plain ply count.
proc ::cr_review::bookInfo {} {
    variable R
    if {[info exists R(bookInfo)]} { return $R(bookInfo) }
    set flags {}
    set src plies
    if {$::cr_settings::s(book_mode) eq "book"} {
        set flags [::cr_review::bookFlags]
        if {[llength $flags]} { set src book }
    }
    if {![llength $flags]} {
        if {$::cr_settings::s(book_mode) eq "plies"} {
            set end $::cr_settings::s(book_plies)
        } else {
            # eco mode, or book mode with no usable book: the ECO probe
            set end [::cr_review::bookEndPly]
            set src eco
        }
        if {$end > $R(n)} { set end $R(n) }
        if {$end < 0} { set end 0 }
        for {set i 0} {$i < $R(n)} {incr i} {
            lappend flags [expr {$i < $end ? 1 : 0}]
        }
    }
    set start $R(n)
    set firstZero [lsearch -exact $flags 0]
    if {$firstZero >= 0} { set start $firstZero }
    set R(bookEnd) $start
    set R(bookInfo) [dict create start $start flags $flags source $src]
    catch { ::cr_review::log "book: source=$src first non-book position=$start of $R(n)" }
    return $R(bookInfo)
}

# Per-ply book flags straight from the opening book: walk the main line, ask
# the book for the moves it offers at each position, and stop counting at the
# first ply whose played move the book does not contain. Returns "" when the
# probe cannot run, so the caller can fall back to the ECO answer.
proc ::cr_review::bookFlags {} {
    variable R
    set file [::cr_settings::bookFile]
    if {$file eq ""} {
        catch { ::cr_review::log "book probe: no readable book file" }
        return ""
    }
    if {[catch { sc_book load $file 2 } err]} {
        catch { ::cr_review::log "book probe: cannot load $file ($err)" }
        return ""
    }
    set flags {}
    set inBook 1
    set ok 0
    if {[catch {
        sc_game push
        for {set k 1} {$k <= $R(n)} {incr k} {
            set bookMoves {}
            if {$inBook} { catch { lassign [sc_book moves 2] bookMoves } }
            ::uci::sc_move_add [list [lindex $R(moves) [expr {$k - 1}]]]
            set san [sc_game info previousMoveNT]
            if {$inBook} {
                set hit 0
                foreach {m p} $bookMoves {
                    if {$m eq $san} { set hit 1 ; break }
                }
                if {$hit} {
                    lappend flags 1
                } else {
                    lappend flags 0
                    set inBook 0
                }
            } else {
                lappend flags 0
            }
        }
        set ok 1
    } err]} {
        catch { ::cr_review::log "book probe failed: $err" }
    }
    catch { sc_game pop }
    catch { sc_book close 2 }
    if {!$ok} { return "" }
    catch { ::cr_review::log "book probe: [llength $flags] plies walked, [lsearch -exact $flags 0] book plies" }
    return $flags
}

# Position index where the engine pass should start.
proc ::cr_review::bookSkipStart {} {
    variable R
    set info [::cr_review::bookInfo]
    if {!$::cr_settings::s(skip_book)} { return 0 }
    set start [dict get $info start]
    set R(firstSearch) [expr {min($start, $R(n))}]
    return $R(firstSearch)
}


proc ::cr_review::start {} {
    variable R
    global errorInfo
    set ::cr_review::cancel 0
    ::cr_review::log "start (base=[sc_base current], game=[sc_game number])"
    if {[sc_game number] < 1} {
        tk_messageBox -icon info -title "scidCommunity" -message \
            "This game is not in a database yet.\n\nSave it first, then run the review."
        return
    }
    if {[sc_var level]} {
        tk_messageBox -icon info -title "scidCommunity" -message \
            "Annotations are written to the main line. Leave the variation first (Up)."
        return
    }
    if {[sc_base isReadOnly [sc_base current]]} {
        tk_messageBox -icon info -title "scidCommunity" -message \
            "The current database is read-only: its games cannot be annotated."
        return
    }
    ::cr_review::log "checks passed (readable, main line)"
    set ml [sc_game UCI_mainLine]
    ::cr_review::log "mainline elements: [llength $ml]"
    if {[llength $ml] < 2} {
        tk_messageBox -icon info -title "scidCommunity" -message "This game has no moves."
        return
    }
    if {[catch { ::cr_review::buildLine $ml } err]} {
        tk_messageBox -icon warning -title "scidCommunity" -message $err
        return
    }
    ::cr_review::log "line built: $R(n) plies, [llength $R(positions)] positions"

    # The window goes up before any of the newly added work starts: the book
    # probe and the cloud pre-pass take seconds, and a board that does nothing
    # for that long reads as a hang. Everything after this point reports into
    # this window.
    ::cr_review::progressStart

    set first [::cr_review::bookSkipStart]
    set info [::cr_review::bookInfo]
    ::cr_review::log "book: source=[dict get $info source], first searched position $first (skip_book=$::cr_settings::s(skip_book))"

    # Cloud pre-pass: positions the community has already analysed deeply come
    # back in a fraction of a second, so ask for all of them before spending
    # minutes of local search. What the cloud does not cover is searched locally.
    if {$::cr_settings::s(cloud_mode) ne "off"} {
        ::cr_review::log "cloud pre-pass: mode=$::cr_settings::s(cloud_mode) min depth=$::cr_settings::s(cloud_min_depth) min pvs=$::cr_settings::s(cloud_min_pv)"
        ::cr_ui::progressStage "Cloud evaluations" [expr {[llength $R(fens)] - $first}]
        ::cr_engine::cloudPrefill [dict create \
            fens $R(fens) startIndex $first \
            mode $::cr_settings::s(cloud_mode) \
            minDepth $::cr_settings::s(cloud_min_depth) \
            minPv $::cr_settings::s(cloud_min_pv) \
            onProgress ::cr_review::onCloudProgress \
            onDone ::cr_review::onCloudDone]
        return
    }
    ::cr_review::beginAnalysis {}
}

# Open the window on the work that happens before the engine starts, so the
# user sees the review running rather than a frozen board.
proc ::cr_review::progressStart {} {
    catch { ::cr_ui::progressOpen 1 "opening book" }
    catch { ::cr_ui::progressStage "Opening book" 1 }
}

proc ::cr_review::onCloudProgress {done total {accepted 0}} {
    catch { ::cr_ui::progressSet $done $total "Cloud evaluations ($accepted usable)" }
}

proc ::cr_review::onCloudDone {prefilled stats} {
    variable R
    set R(prefilled) $prefilled
    if {[info exists ::cr_review::cancel] && $::cr_review::cancel} {
        catch { ::cr_ui::progressClose }
        return
    }
    ::cr_review::beginAnalysis $prefilled
}

# Start the engine pass over whatever the cloud did not cover.
proc ::cr_review::beginAnalysis {prefilled} {
    variable R
    set first [::cr_review::bookSkipStart]
    set work [expr {[llength $R(positions)] - $first - [dict size $prefilled]}]
    if {$work < 0} { set work 0 }
    ::cr_review::log "analysis: $work positions to search, [dict size $prefilled] prefilled"
    if {$work > 0} {
        ::cr_ui::progressStage "Analysing" $work
        ::cr_ui::progressSet 0 $work "Analysing"
    } else {
        # nothing left to search: all of it was book or came from the cloud
        ::cr_ui::progressStage "Writing annotations" 1
        ::cr_ui::progressSet 1 1 "Writing annotations"
    }
    set rc [::cr_review::launch $prefilled]
    ::cr_review::log "engine launch returned: $rc"
}


# Turn scid's "position ... moves" list into one position string per ply,
# plus the FEN of every ply worked out on our own board.
proc ::cr_review::buildLine {ml} {
    variable R
    array unset R
    array set R {}
    set positions {}
    set cur ""
    set moves {}
    foreach e $ml {
        if {[string match "position *" $e]} {
            if {$cur ne "" && [llength $positions] > 1} {
                error "This game contains a null move (a fresh starting position).\nReview each segment separately."
            }
            set cur $e
            lappend positions $cur
        } else {
            append cur " $e"
            lappend positions $cur
            lappend moves $e
        }
    }
    set R(positions) $positions
    set R(moves) $moves
    set R(n) [llength $moves]

    # starting FEN
    set head [lindex $ml 0]
    if {[regexp {^position fen (.+) moves$} $head -> f]} {
        set startFen $f
    } else {
        set startFen "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    }
    set pos [::crboard::fromFen $startFen]
    set fens [list $startFen]
    foreach m $moves {
        set pos [::crboard::makeMove $pos $m]
        lappend fens [::crboard::toFen $pos]
    }
    set R(fens) $fens
    return ok
}

proc ::cr_review::launch {{prefilled {}}} {
    variable R
    ::cr_review::log "launch: engine1='$::cr_settings::s(engine_analysis)' depth=$::cr_settings::s(depth) prefilled=[dict size $prefilled]"
    set opts [dict create \
        positions $R(positions) \
        startIndex [::cr_review::bookSkipStart] \
        depth $::cr_settings::s(depth) \
        engine1 $::cr_settings::s(engine_analysis) \
        prefilled $prefilled \
        engine2 [expr {$::cr_settings::s(verify_mode) eq "off" ? "" : $::cr_settings::s(engine_verify)}] \
        onStatus ::cr_review::onStatus \
        onDone ::cr_review::onEngineDone \
        onError ::cr_review::onError]
    ::cr_engine::run $opts
}

proc ::cr_review::onStatus {phase done total} {
    switch -- $phase {
        analysis { ::cr_ui::progressSet $done $total "Analysing" }
        verify   { ::cr_ui::progressSet $done $total "Verifying" }
        default  { ::cr_ui::progressSet $done $total $phase }
    }
}

proc ::cr_review::onError {msg} {
    ::cr_ui::progressClose
    if {[info exists ::cr_review::cancel] && $::cr_review::cancel} {
        catch { ::cr_ui::proseNote "Cancelled." }
        return
    }
    tk_messageBox -icon warning -title "scidCommunity" -message "Review failed:\n\n$msg"
}

proc ::cr_review::onEngineDone {status} {
    variable R
    ::cr_review::log "analysis pass: $status"
    if {$status ne "ok"} { return }
    if {[catch {
        set R(evals) [::cr_engine::evals]
        ::cr_review::classifyAll
        set idx [::cr_review::verifyIndices]
        if {[llength $idx] &&
            $::cr_settings::s(verify_mode) ne "off" &&
            $::cr_settings::s(engine_verify) ne "" &&
            $::cr_settings::s(engine_verify) ne $::cr_settings::s(engine_analysis)} {
            ::cr_ui::progressSet 0 [llength $idx] "Verifying"
            ::cr_engine::verify [dict create \
                positions $R(positions) indices $idx depth $::cr_settings::s(depth) \
                engine2 $::cr_settings::s(engine_verify) \
                onStatus ::cr_review::onStatus \
                onDone ::cr_review::onVerifyDone onError ::cr_review::onError]
        } else {
            ::cr_review::finish
        }
    } err]} {
        ::cr_ui::progressClose
        tk_messageBox -icon warning -title "scidCommunity" -message "Review failed:\n\n$err"
    }
}

proc ::cr_review::onVerifyDone {status args} {
    variable R
    if {$status eq "ok"} {
        set R(vres) [::cr_engine::verifications]
        catch { ::cr_review::applyVerification }
    }
    ::cr_review::finish
}

proc ::cr_review::finish {} {
    variable R
    ::cr_review::log "writing annotations"
    # One database search per review at most: the tree line costs a filter scan,
    # so it stays opt-in and is computed once, before the report is built.
    if {$::cr_settings::s(tree_stats)} {
        if {[catch { set R(treeLine) [::crfacts::treeLine] } terr]} {
            ::cr_review::log "tree stats failed: $terr"
        }
        if {[info exists R(treeLine)] && $R(treeLine) ne ""} {
            ::cr_review::log "tree stats: $R(treeLine)"
        }
    }
    if {[catch {
        ::cr_review::writeGame
        ::cr_ui::progressClose
        ::cr_ui::reportOpen
        ::cr_review::log "done: [dict get $R(counts) blunder] blunders, accuracy $R(acc,white)/$R(acc,black)"
    } err]} {
        ::cr_review::log "write/report FAILED: $err"
        catch { ::cr_ui::progressClose }
        tk_messageBox -icon warning -title "scidCommunity" \
            -message "Annotations were not written:\n\n$err"
        return
    }
    if {$::cr_settings::s(llm_enabled) && $::cr_settings::s(api_key) ne ""} {
        if {[catch { ::cr_llm::startProse } err]} {
            ::cr_review::log "coach failed: $err"
            catch { ::cr_ui::proseNote "Coach unavailable: $err" }
        }
    }
}

proc ::cr_review::moveByPly {ply} {
    variable R
    foreach m $R(movesOut) {
        if {[dict get $m ply] == $ply} { return $m }
    }
    return ""
}

proc ::cr_review::verifyIndices {} {
    variable R
    set idx {}
    foreach m $R(movesOut) {
        if {[dict get $m classification] in {brilliant great}} {
            lappend idx [expr {[dict get $m ply] - 1}]
        }
    }
    return [lsort -unique $idx]
}

# ---- analysis -> per-ply records -------------------------------------------

proc ::cr_review::evalToCp {score type} {
    if {$type eq "mate"} {
        if {$score > 0} { return [expr {10000 - $score * 10}] }
        return [expr {-10000 - $score * 10}]
    }
    return $score
}

# candidates of the position analysed at index k, best first, as
# {cp pv} pairs (cp from the side-to-move = the player's perspective)
proc ::cr_review::candidates {k} {
    variable R
    set d [dict create]
    if {[info exists R(evals)] && [dict exists $R(evals) $k]} { set d [dict get $R(evals) $k] }
    set out {}
    foreach mpv [lsort -integer [dict keys $d]] {
        lassign [dict get $d $mpv] score type pv depth
        lappend out [list [evalToCp $score $type] $pv]
    }
    return $out
}

# Number of leading plies that are still theory - the first ply at which the
# game leaves the ECO book. Found by replaying the main line into a scratch
# game (sc_game push/pop, the pattern scid's own tools use) and asking for the
# deepest ECO match after each move: while move k still lands on book, the
# answer is k; the first k where it is lower is the exit.
# Closes the transposition hole: scid's one-shot "eco ply" reports the deepest
# match anywhere in the game, which over-extends the book when a game wanders
# out and back in.
# Returns "" if the probe could not run, so the caller can fall back.
proc ::cr_review::firstExitPly {} {
    variable R
    set n $R(n)
    if {$n < 1} { return 0 }
    set exitPly ""
    set ok 0
    if {[catch {
        sc_game push
        for {set k 1} {$k <= $n} {incr k} {
            ::uci::sc_move_add [list [lindex $R(moves) [expr {$k - 1}]]]
            set p 0
            catch { set p [sc_game eco ply] }
            if {![string is integer -strict $p]} { set p 0 }
            if {$p < $k} { set exitPly [expr {$k - 1}] ; break }
        }
        if {$exitPly eq ""} { set exitPly $n }
        set ok 1
    } err]} {
        ::cr_review::log "book probe failed: $err"
    }
    catch { sc_game pop }
    if {!$ok} { return "" }
    return $exitPly
}

# Last ply whose position scid's ECO book recognises (deepest match). Kept as
# the fallback when the per-ply probe is unavailable.
proc ::cr_review::ecoBookEnd {} {
    if {[llength [info commands sc_game]] == 0} { return 0 }
    if {[catch { sc_game eco ply } p]} { return 0 }
    if {![string is integer -strict $p]} { return 0 }
    return $p
}

proc ::cr_review::bookEndPly {} {
    variable R
    if {$::cr_settings::s(book_mode) eq "eco"} {
        set e [::cr_review::firstExitPly]
        if {$e ne ""} { return $e }
        ::cr_review::log "book probe unavailable; falling back to scid's deepest ECO match"
        set p [::cr_review::ecoBookEnd]
        if {$p > 0} { return $p }
    }
    return $::cr_settings::s(book_plies)
}

proc ::cr_review::classifyAll {} {
    variable R
    set R(movesOut) {}
    set R(keyInput) {}
    set bookFlags [dict get [::cr_review::bookInfo] flags]

    # Repetition is a property of the sequence, not of one FEN: count how often
    # each position has occurred up to and including itself.
    set repCounts {}
    set seenSig [dict create]
    foreach f $R(fens) {
        set g [::crfacts::sig $f]
        dict incr seenSig $g
        lappend repCounts [dict get $seenSig $g]
    }

    for {set i 1} {$i <= $R(n)} {incr i} {
        set fenBefore [lindex $R(fens) [expr {$i - 1}]]
        set fenAfter  [lindex $R(fens) $i]
        set sideW [expr {[lindex [split $fenBefore] 1] eq "b" ? "black" : "white"}]

        # A book ply was never searched: label it Book and move on. Its evals
        # are unknown, and the book rule would return 'book' anyway unless the
        # move was a blunder - which no searched game can show without evals.
        if {[lindex $bookFlags [expr {$i - 1}]]} {
            lappend R(movesOut) [dict create ply $i side $sideW \
                played [lindex $R(moves) [expr {$i - 1}]] \
                fen_before $fenBefore fen_after $fenAfter \
                eval_before_cp 0 eval_after_cp 0 player_before 0 player_after 0 \
                cp_loss 0 wp_drop 0.0 best_uci "" best_san "" best_pv {} \
                best_pv_uci {} candidates {} legal 0 classification book \
                unsearched 1]
            continue
        }

        set cBefore [::cr_review::candidates [expr {$i - 1}]]
        set cAfter  [::cr_review::candidates $i]

        # best move: first move of the top candidate's PV
        set bestUci ""
        set bestPv {}
        if {[llength $cBefore]} {
            set bestPv [lindex [lindex $cBefore 0] 1]
            set bestUci [lindex $bestPv 0]
        }
        set candCps [lmap c $cBefore {lindex $c 0}]
        # The engine's score for the best alternative. It is the value of the
        # line that gets written as a variation, so the variation ends with it.
        set bestCp [expr {[llength $candCps] ? [lindex $candCps 0] : 0}]
        # $sideB is not in scope yet here: read the side off the FEN
        set bestWhite [expr {[lindex [split $fenBefore] 1] eq "w" ? $bestCp : -$bestCp}]

        # white-perspective evals for the two positions
        set sideB [lindex [split $fenBefore] 1]
        set ebCp 0 ; set eaCp 0
        if {[llength $cBefore]} { set ebCp [lindex [lindex $cBefore 0] 0] }
        if {[llength $cAfter]}  { set eaCp [lindex [lindex $cAfter 0] 0] }
        set ebWhite [expr {$sideB eq "w" ? $ebCp : -$ebCp}]
        set eaWhite [expr {$sideB eq "w" ? -$eaCp : $eaCp}]

        # player-perspective evals (for the rules)
        set pb [expr {$sideW eq "white" ? $ebWhite : -$ebWhite}]
        set pa [expr {$sideW eq "white" ? $eaWhite : -$eaWhite}]

        set wpB [::crclass::cpToWinPct $ebWhite]
        set wpA [::crclass::cpToWinPct $eaWhite]
        set playerWpB [expr {$sideW eq "white" ? $wpB : 100 - $wpB}]
        set playerWpA [expr {$sideW eq "white" ? $wpA : 100 - $wpA}]
        set wpDrop [::crclass::winDropForPly $pb $pa $playerWpB $playerWpA]
        set cpLoss [::crclass::cpLossForPly $pb $pa]

        set posBefore [::crboard::fromFen $fenBefore]
        set legal [llength [::crboard::legalMoves $posBefore]]
        set playedUci [lindex $R(moves) [expr {$i - 1}]]

        set isBest [expr {$bestUci ne "" && $bestUci eq $playedUci}]
        set base [::crclass::classifyByWpDrop $wpDrop $cpLoss $isBest]
        set cls [::crclass::refineClassification \
            -base $base -isBest $isBest -cpLoss $cpLoss \
            -fenBefore $fenBefore -fenAfter $fenAfter -sideToMove $sideW \
            -playerEvalBeforeCp $pb -playerEvalAfterCp $pa -ply $i \
            -legalMoveCount $legal -candidatePlayerCps $candCps \
            -pvAfterPlayed [lindex [lindex $cAfter 0] 1] \
            -inBook [expr {$i <= $R(bookEnd)}] -playedUci $playedUci -winDrop $wpDrop]

        set bestSan ""
        if {$bestUci ne "" && [llength [info commands sc_pos]]} {
            catch { set bestSan [sc_pos coordToSAN $fenBefore $bestUci] }
        }
        # sc_pos coordToSAN takes the position plus the whole coord-move
        # string in one call; converting move by move re-plays each one from
        # the original position and is wrong from the second move on.
        set pvSan {}
        set pvLong {}
        set pvLimit $::cr_settings::s(pv_moves)
        if {[llength $bestPv] && $pvLimit > 0 && [llength [info commands sc_pos]]} {
            set slice [lrange $bestPv 0 [expr {$pvLimit - 1}]]
            if {![catch { set sanStr [sc_pos coordToSAN $fenBefore [join $slice " "]] }]} {
                if {$sanStr ne ""} { set pvSan [split $sanStr " "] }
            }
            # the coach gets more of the line than the scoresheet does
            set sliceLong [lrange $bestPv 0 9]
            if {![catch { set sanLong [sc_pos coordToSAN $fenBefore [join $sliceLong " "]] }]} {
                if {$sanLong ne ""} { set pvLong [split $sanLong " "] }
            }
        }

        set rec [dict create ply $i side $sideW played $playedUci \
            fen_before $fenBefore fen_after $fenAfter \
            eval_before_cp $ebWhite eval_after_cp $eaWhite \
            player_before $pb player_after $pa \
            cp_loss $cpLoss wp_drop $wpDrop best_uci $bestUci best_san $bestSan \
            best_pv $pvSan best_pv_long $pvLong best_pv_uci $bestPv candidates $candCps legal $legal \
            best_cp_white $bestWhite rep_count [lindex $repCounts $i] \
            classification $cls]
        lappend R(movesOut) $rec

        lappend R(keyInput) [dict create ply $i classification $cls \
            eval_before_cp $ebWhite eval_after_cp $eaWhite \
            san "" fen_before $fenBefore fen_after $fenAfter \
            centipawn_loss $cpLoss best_move_san $bestSan best_pv $pvSan]
    }

    # accuracy / Elo per side
    set wPts {} ; set bPts {}
    set wAcpl {} ; set bAcpl {}
    foreach m $R(movesOut) {
        set side [dict get $m side]
        set cls [dict get $m classification]
        if {[dict exists $m unsearched]} continue
        set isBook [expr {$cls eq "book" || $cls eq "forced"}]
        set wpA [::crclass::cpToWinPct [dict get $m eval_after_cp]]
        set playerWpA [expr {$side eq "white" ? $wpA : 100 - $wpA}]
        set acc [::crclass::moveAccuracy [dict get $m player_before] [dict get $m player_after]]
        set pt [list $acc $playerWpA $isBook]
        if {$side eq "white"} {
            lappend wPts $pt
            if {!$isBook} { lappend wAcpl [::crclass::cpLossForAcpl [dict get $m player_before] [dict get $m player_after]] }
        } else {
            lappend bPts $pt
            if {!$isBook} { lappend bAcpl [::crclass::cpLossForAcpl [dict get $m player_before] [dict get $m player_after]] }
        }
    }
    set accW [::crclass::gameAccuracy $wPts]
    set accB [::crclass::gameAccuracy $bPts]
    set acplW [expr {[llength $wAcpl] ? [::cr_review::mean $wAcpl] : 0}]
    set acplB [expr {[llength $bAcpl] ? [::cr_review::mean $bAcpl] : 0}]

    set R(acc,white) [expr {round($accW * 10) / 10.0}]
    set R(acc,black) [expr {round($accB * 10) / 10.0}]
    set R(acpl,white) $acplW
    set R(acpl,black) $acplB
    # game phases: decided by the position, never by the book
    set R(phaseStats) [::crclass::phaseSplit $R(movesOut)]
    foreach ph {opening middlegame endgame} {
        set st [dict get $R(phaseStats) $ph]
        if {$st eq ""} {
            ::cr_review::log "phase $ph: no prose (fewer than 4 plies)"
        } else {
            ::cr_review::log "phase $ph: plies [dict get $st from_ply]-[dict get $st to_ply], \
                acc W [dict get $st accuracy_white] B [dict get $st accuracy_black]"
        }
    }

    set R(elo,white) [::crclass::estimateElo $accW $acplW]
    set R(elo,black) [::crclass::estimateElo $accB $acplB]

    # performance rating, only when the PGN carries an opponent rating
    set R(perf,white) ""
    set R(perf,black) ""
    set opp [expr {[sc_game tags get BlackElo] eq "" ? 0 : [sc_game tags get BlackElo]}]
    set me  [expr {[sc_game tags get WhiteElo] eq "" ? 0 : [sc_game tags get WhiteElo]}]
    set res [sc_game tags get Result]
    if {$opp > 0} {
        set R(perf,white) [::crclass::estimateGamePerformance -accuracy $accW -acpl $acplW \
            -opponentRating $opp -opponentRd $::cr_settings::s(opponent_rd) \
            -score [::cr_review::scoreFor white $res]]
    }
    if {$me > 0} {
        set R(perf,black) [::crclass::estimateGamePerformance -accuracy $accB -acpl $acplB \
            -opponentRating $me -opponentRd $::cr_settings::s(opponent_rd) \
            -score [::cr_review::scoreFor black $res]]
    }

    set R(keyMoments) [::crclass::extractKeyMoments $R(keyInput) 5]
    set R(counts) [::cr_review::countLabels $R(movesOut)]
    return ok
}

proc ::cr_review::mean {xs} {
    set s 0.0 ; foreach x $xs { set s [expr {$s + $x}] }
    return [expr {$s / [llength $xs]}]
}

proc ::cr_review::scoreFor {color result} {
    switch -- $result {
        1-0   { return [expr {$color eq "white" ? 1 : 0}] }
        0-1   { return [expr {$color eq "white" ? 0 : 1}] }
        default { return 0.5 }
    }
}

proc ::cr_review::countLabels {moves} {
    variable LABEL
    set c [dict create]
    foreach k [array names LABEL] { dict set c $k 0 }
    foreach m $moves { dict incr c [dict get $m classification] }
    return $c
}

# ---- verifier --------------------------------------------------------------

# A Brilliant/Great upgrade is withdrawn when the second engine disagrees on
# the best move, or does not see the only-good-move gap at all.
proc ::cr_review::applyVerification {} {
    variable R
    if {![info exists R(vres)] || [dict size $R(vres)] == 0} { return }
    set out {}
    foreach m $R(movesOut) {
        set cls [dict get $m classification]
        set k [expr {[dict get $m ply] - 1}]
        if {[lsearch -exact {brilliant great} $cls] >= 0 && [dict exists $R(vres) $k]} {
            set d [dict get $R(vres) $k]
            set top ""
            if {[dict exists $d 1]} { set top [lindex [lindex [dict get $d 1] 2] 0] }
            set down 0
            if {$top eq "" || $top ne [dict get $m best_uci]} { set down 1 }
            if {!$down && $cls eq "great" && [dict exists $d 2]} {
                set cp1 [evalToCp [lindex [dict get $d 1] 0] [lindex [dict get $d 1] 1]]
                set cp2 [evalToCp [lindex [dict get $d 2] 0] [lindex [dict get $d 2] 1]]
                if {$cp1 - $cp2 < 200} { set down 1 }
            }
            if {$down} { set m [dict set m classification best] }
        }
        lappend out $m
    }
    set R(movesOut) $out
    return ok
}

# ---- writeback -------------------------------------------------------------

proc ::cr_review::fmtEval {cp} {
    if {abs($cp) >= 9000} {
        set n [expr {(10000 - abs($cp)) / 10}]
        if {$n < 1} { set n 1 }
        return [expr {$cp > 0 ? "M$n" : "-M$n"}]
    }
    return [format "%+.2f" [expr {$cp / 100.0}]]
}

proc ::cr_review::stripOurLabels {text} {
    variable LABEL
    set pat {\[(?:Brilliant|Great|Best|Excellent|Good|Book|Forced|Inaccuracy|Mistake|Miss|Blunder)\][^[]*}
    regsub -all $pat $text "" t
    regsub -all {\[%eval [^\]]*\]} $t "" t2
    # A phase block is ours too: marker, figures and prose. Without this the
    # next review would stack a second paragraph on the same ply.
    regsub -all {\[Phase (?:opening|middlegame|endgame)\][^[]*} $t2 "" t3
    return [string trim $t3]
}

proc ::cr_review::moveComment {m} {
    variable LABEL
    set cls [dict get $m classification]
    set txt "\[$LABEL($cls)\]"
    if {[lsearch -exact {best excellent good book} $cls] < 0} {
        # The score is already written as [%eval], from White's side. Repeating
        # the mover's-side figure next to the label produced two numbers that
        # disagreed, so the label stands alone.
        # with variations enabled the line lives on the board, not in the text
        if {!$::cr_settings::s(pv_variation)} {
            set line [dict get $m best_pv]
            if {[llength $line] == 0 && [dict get $m best_san] ne ""} { set line [list [dict get $m best_san]] }
            if {[llength $line]} { append txt ", best " [join $line " "] }
        }
    }
    return $txt
}

proc ::cr_review::writeGame {} {
    variable R
    variable NAG
    set ply0 [sc_pos location]
    undoFeature save
    if {[catch {
        set i 0
        foreach m $R(movesOut) {
            incr i
            if {[catch { sc_move ply $i }]} break
            if {[sc_pos location] != $i} break
            set cls [dict get $m classification]
            if {[info exists NAG($cls)]} { catch { sc_pos addNag $NAG($cls) } }
            # Best line as a real variation: branch at the position before this
            # move, play the engine's line, come back. Only where the played
            # move differs from the engine's choice - otherwise the variation
            # would just repeat the game.
            if {$::cr_settings::s(pv_variation) && $::cr_settings::s(pv_moves) > 0 &&
                [llength [dict get $m best_pv_uci]] > 1 &&
                [lsearch -exact {inaccuracy mistake miss blunder} $cls] >= 0 &&
                [dict get $m played] ne [dict get $m best_uci]} {
                set pv [lrange [dict get $m best_pv_uci] 0 [expr {$::cr_settings::s(pv_moves) - 1}]]
                if {![catch {
                    sc_move back
                    # A variation already branching here belongs to someone
                    # else (or to an earlier run): never stack a second one.
                    if {[catch { sc_var count } vc]} { set vc 0 }
                    if {$vc == 0} {
                        sc_var create
                        ::uci::sc_move_add $pv
                        # The engine already scored this line; write that score
                        # on the variation's last move so the reader can see
                        # what the better move was worth without a search.
                        if {[dict exists $m best_cp_white]} {
                            catch { sc_pos setComment "\[%eval [::cr_review::fmtEval [dict get $m best_cp_white]]\]" }
                        }
                        sc_var exit
                    } else {
                        ::cr_review::log "ply $i: variation already present, skipped"
                    }
                }]} {
                    catch { sc_move ply $i }
                }
            }
            set want [::cr_review::moveComment $m]
            if {$cls in {best excellent good book} && !$::cr_settings::s(comment_all)} { set want "" }
            set comment [::cr_review::stripOurLabels [sc_pos getComment]]
            set new [string trim "$comment $want"]
            if {$::cr_settings::s(write_eval) && ![dict exists $m unsearched]} {
                set tok "\[%eval [::cr_review::fmtEval [dict get $m eval_after_cp]]\]"
                if {[string first "%eval" $new] < 0} { append new " " $tok }
            }
            catch { sc_pos setComment [string trim $new] }

        }
        # game header comment
        set head [::cr_review::headerText]
        sc_move ply 0
        set old [::cr_review::stripOurLabels [sc_pos getComment]]
        regsub -all {\[Game review\][^\[]*} $old "" old
        catch { sc_pos setComment [string trim "[string trim $old] $head"] }
        sc_move ply $ply0
    } err]} {
        undoFeature undo
        error $err
    }
    set gn [sc_game number]
    set base [sc_base current]
    catch { sc_game save $gn }
    catch { ::notify::DatabaseModified $base }
    catch { ::notify::PosChanged -pgn }
    if {[winfo exists .commentWin]} { catch { ::windows::commenteditor::Refresh } }
    return ok
}

proc ::cr_review::headerText {} {
    variable R
    set c $R(counts)
    set parts {}
    lappend parts "\[Game review\]"
    lappend parts "Accuracy White [format %.1f $R(acc,white)]% / Black [format %.1f $R(acc,black)]%."
    lappend parts "Est. Elo White $R(elo,white) / Black $R(elo,black)."
    if {$R(perf,white) ne ""} { lappend parts "Performance White $R(perf,white)." }
    if {$R(perf,black) ne ""} { lappend parts "Performance Black $R(perf,black)." }
    set tally {}
    foreach k {brilliant great inaccuracy mistake miss blunder} {
        if {[dict get $c $k] > 0} { lappend tally "[dict get $c $k] $k" }
    }
    if {[llength $tally]} { lappend parts "[join $tally {, }]." }
    return [join $parts " "]
}

# ---- report ----------------------------------------------------------------

proc ::cr_review::reportText {} {
    variable R
    variable LABEL
    set out {}
    lappend out "Accuracy      White [format %.1f $R(acc,white)]%   Black [format %.1f $R(acc,black)]%"
    lappend out "ACPL          White [format %.1f $R(acpl,white)]    Black [format %.1f $R(acpl,black)]"
    lappend out "Est. Elo      White $R(elo,white)        Black $R(elo,black)"
    if {$R(perf,white) ne "" || $R(perf,black) ne ""} {
        lappend out "Performance   White [expr {$R(perf,white) eq "" ? "-" : $R(perf,white)}]          Black [expr {$R(perf,black) eq "" ? "-" : $R(perf,black)}]"
    }
    set c $R(counts)
    set tally {}
    foreach k {brilliant great best excellent good book inaccuracy mistake miss blunder} {
        if {[dict get $c $k] > 0} { lappend tally "[dict get $c $k] $k" }
    }
    lappend out ""
    lappend out "Moves         [join $tally {, }]"
    lappend out ""
    if {[info exists R(summary)] && $R(summary) ne ""} {
        lappend out ""
        lappend out "Summary"
        foreach line [split $R(summary) "\n"] { lappend out "  [string trim $line]" }
        if {[info exists R(summaryOpening)] && $R(summaryOpening) ne ""} {
            lappend out ""
            lappend out "  Opening: $R(summaryOpening)"
        }
        if {[info exists R(summaryLevel)] && $R(summaryLevel) ne ""} {
            lappend out "  Level: $R(summaryLevel)"
        }
    }
    if {[info exists R(phaseStats)]} {
        set any 0
        foreach ph {opening middlegame endgame} {
            if {[dict get $R(phaseStats) $ph] ne ""} { set any 1 ; break }
        }
        if {$any} {
            lappend out ""
            lappend out "Phases"
            foreach ph {opening middlegame endgame} {
                set st [dict get $R(phaseStats) $ph]
                if {$st eq ""} continue
                lappend out [format "  %-11s plies %d-%d   accuracy W %5.1f%% B %5.1f%%   acpl W %d B %d" \
                    $ph [dict get $st from_ply] [dict get $st to_ply] \
                    [dict get $st accuracy_white] [dict get $st accuracy_black] \
                    [dict get $st acpl_white] [dict get $st acpl_black]]
                if {[info exists R(phase,$ph)]} {
                    lappend out "    $R(phase,$ph)"
                }
            }
        }
    }
    lappend out ""
    lappend out "Key moments"
    foreach k $R(keyMoments) {
        set ply [dict get $k ply]
        set mv [expr {($ply + 1) / 2}]
        set dots [expr {$ply % 2 ? "." : "..."}]
        lappend out [format "  %d%-3s %-11s  -%d cp / %.1f wp   %s" $mv $dots \
            [string totitle [dict get $k classification]] \
            [dict get $k cp_loss] [dict get $k win_pct_delta] \
            [expr {[dict get $k best_san] eq "" ? "" : "best: [dict get $k best_san]"}]]
    }
    return [join $out "\n"]
}
