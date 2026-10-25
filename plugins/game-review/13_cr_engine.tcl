# cr_engine.tcl -- headless multi-PV engine pass for the review plugin.
#
# Uses scid's own engine layer (::engineNoWin / ::engine::send), so Windows
# pipes, engine configuration and process lifetime stay scid's business.
# Two entry points:
#   run     one MultiPV search per position of the main line   (engine id 20)
#   verify  re-search chosen positions with a second engine    (engine id 21)
# Neither touches Tk; the caller passes status/done callbacks.

namespace eval ::cr_engine {
    variable A          ;# analysis pass
    variable V          ;# verification pass
    array set A {}
    array set V {}
    variable MULTIPV 3

    # Cloud-evaluation pre-pass (lichess.org/api/cloud-eval, chessdb fallback).
    variable CLOUD_URL "https://lichess.org/api/cloud-eval"
    variable CLOUD_CHESSDB "http://www.chessdb.cn/cdb.php"
    variable CLOUD        ;# in-flight pre-pass state
    variable CLOUD_CACHE  ;# fen -> {multipv dict} or "" for a miss
    array set CLOUD {}
    array set CLOUD_CACHE {}
}


# ---------------------------------------------------------------- analysis --
# options: positions (list, index 0 = start), depth, engine1,
#          onStatus(done total), onDone(status), onError(msg)
proc ::cr_engine::run {options} {
    variable A
    variable MULTIPV
    array unset A
    set start [expr {[dict exists $options startIndex] ? [dict get $options startIndex] : 0}]
    array set A [dict create i $start evals {} engine1 [dict get $options engine1] \
        depth [dict get $options depth] start $start]
    set A(positions) [dict get $options positions]
    set A(total) [llength $A(positions)]
    set A(onStatus) [expr {[dict exists $options onStatus] ? [dict get $options onStatus] : ""}]
    set A(onDone) [expr {[dict exists $options onDone] ? [dict get $options onDone] : ""}]
    set A(onError) [expr {[dict exists $options onError] ? [dict get $options onError] : ""}]

    # Positions already evaluated elsewhere (the cloud pre-pass) go straight
    # into the results and never reach the engine. Everything else is queued.
    set A(prefilled) [expr {[dict exists $options prefilled] ? [dict get $options prefilled] : {}}]
    set A(queue) {}
    for {set k $start} {$k < $A(total)} {incr k} {
        if {[dict exists $A(prefilled) $k]} {
            set A(evals,$k) [dict get $A(prefilled) $k]
        } else {
            lappend A(queue) $k
        }
    }
    set A(work) [llength $A(queue)]
    set A(q) 0

    if {$A(work) < 1} {
        # nothing left to search (all book, or every position came from the
        # cloud): report done at once
        catch { ::cr_review::log "engine 20: nothing to search ($A(total) positions, [dict size $A(prefilled)] from the cloud)" }
        if {$A(onDone) ne ""} { {*}$A(onDone) ok }
        return ok
    }
    if {[catch {
        ::engineNoWin::initEngine 20 $A(engine1) [list ::cr_engine::onAnalysisMsg]
    } err]} {
        return [error_ analysis "cannot start engine '$A(engine1)': $err"]
    }
    catch { ::cr_review::log "engine 20 connected: $A(engine1), $A(work) positions to search, [dict size $A(prefilled)] from the cloud" }
    ::engine::send 20 SetOptions [list [list MultiPV $MULTIPV] [list Threads $::cr_settings::s(threads)] [list Hash $::cr_settings::s(hash_mb)]]
    ::cr_engine::status_ analysis 0 $A(work)
    ::cr_engine::watch_ analysis
    ::cr_engine::nextPos
    return ok
}

proc ::cr_engine::nextPos {} {
    variable A
    if {$A(q) >= [llength $A(queue)]} {
        catch { ::engineNoWin::closeEngine 20 }
        catch { after cancel $A(watch) }
        if {$A(onDone) ne ""} { {*}$A(onDone) ok }
        return
    }
    set A(curidx) [lindex $A(queue) $A(q)]
    catch { ::engine::send 20 Go [list [lindex $A(positions) $A(curidx)] [list [list depth $A(depth)]]] }
}

proc ::cr_engine::onAnalysisMsg {msg} {
    variable A
    if {![array exists A] || ![info exists A(q)]} { return }
    ::cr_engine::watch_ analysis
    lassign $msg tag data
    switch -- $tag {
        InfoPV { ::cr_engine::collect A $data }
        InfoBestMove {
            set A(evals,$A(curidx)) [expr {[info exists A(cur)] ? $A(cur) : [dict create]}]
            catch { unset A(cur) }
            incr A(q)
            set done $A(q)
            if {$done == 1 || $done % 10 == 0 || $done >= [llength $A(queue)]} {
                catch { ::cr_review::log "engine 20: $done/$A(work) positions (ply $A(curidx))" }
            }
            ::cr_engine::status_ analysis $done $A(work)
            ::cr_engine::nextPos
        }
        InfoDisconnected { ::cr_engine::error_ analysis "engine disconnected: $data" }
    }
}

# Results of the analysis pass: dict, position index -> {multipv -> {score type pv depth}}
proc ::cr_engine::evals {} {
    variable A
    set out [dict create]
    foreach k [array names A "evals,*"] {
        dict set out [string range $k 6 end] $A($k)
    }
    return $out
}

# ------------------------------------------------------------ verification --
# options: positions, indices (which positions to re-search), depth, engine2,
#          onStatus(done total), onDone(status), onError(msg)
proc ::cr_engine::verify {options} {
    variable V
    array unset V
    array set V [dict create vi 0 results {} engine2 [dict get $options engine2] \
        depth [dict get $options depth]]
    set V(positions) [dict get $options positions]
    set V(indices) [dict get $options indices]
    set V(total) [llength $V(indices)]
    set V(onStatus) [expr {[dict exists $options onStatus] ? [dict get $options onStatus] : ""}]
    set V(onDone) [expr {[dict exists $options onDone] ? [dict get $options onDone] : ""}]
    set V(onError) [expr {[dict exists $options onError] ? [dict get $options onError] : ""}]

    if {$V(total) == 0} {
        if {$V(onDone) ne ""} { {*}$V(onDone) ok }
        return ok
    }
    if {[catch {
        ::engineNoWin::initEngine 21 $V(engine2) [list ::cr_engine::onVerifyMsg]
    } err]} {
        return [error_ verify "cannot start engine '$V(engine2)': $err"]
    }
    ::engine::send 21 SetOptions [list [list MultiPV 3] [list Threads $::cr_settings::s(threads)] [list Hash $::cr_settings::s(hash_mb)]]
    ::cr_engine::status_ verify 0 $V(total)
    ::cr_engine::watch_ verify
    ::cr_engine::nextVerify
    return ok
}

proc ::cr_engine::nextVerify {} {
    variable V
    if {$V(vi) >= $V(total)} {
        catch { ::engineNoWin::closeEngine 21 }
        catch { after cancel $V(watch) }
        if {$V(onDone) ne ""} { {*}$V(onDone) ok }
        return
    }
    set k [lindex $V(indices) $V(vi)]
    set V(curK) $k
    set d [expr {$V(depth) + 4}]
    catch { ::engine::send 21 Go [list [lindex $V(positions) $k] [list [list depth $d]]] }
}

proc ::cr_engine::onVerifyMsg {msg} {
    variable V
    if {![array exists V] || ![info exists V(vi)]} { return }
    ::cr_engine::watch_ verify
    lassign $msg tag data
    switch -- $tag {
        InfoPV { ::cr_engine::collect V $data }
        InfoBestMove {
            dict set V(results) $V(curK) [expr {[info exists V(cur)] ? $V(cur) : [dict create]}]
            catch { unset V(cur) }
            incr V(vi)
            ::cr_engine::status_ verify $V(vi) $V(total)
            ::cr_engine::nextVerify
        }
        InfoDisconnected { ::cr_engine::error_ verify "engine disconnected: $data" }
    }
}

proc ::cr_engine::verifications {} {
    variable V
    if {![info exists V(results)]} { return [dict create] }
    return $V(results)
}

# ------------------------------------------------------------------ shared --
proc ::cr_engine::collect {stateName data} {
    upvar #0 ::cr_engine::$stateName S
    lassign $data multipv depth seldepth nodes nps hashfull tbhits time score score_type score_wdl pv
    if {$score eq ""} { return }
    if {[lsearch -exact {cp mate} $score_type] < 0} { return }
    if {![string is integer -strict $multipv]} { set multipv 1 }
    if {![info exists S(cur)]} { set S(cur) [dict create] }
    if {[dict exists $S(cur) $multipv]} {
        set oldDepth [lindex [dict get $S(cur) $multipv] 3]
        if {[string is integer -strict $depth] && [string is integer -strict $oldDepth] && $depth < $oldDepth} { return }
    }
    dict set S(cur) $multipv [list $score $score_type $pv $depth]
}

proc ::cr_engine::status_ {which done total} {
    variable A
    variable V
    set cb ""
    if {$which eq "analysis" && [array exists A] && [info exists A(onStatus)]} { set cb $A(onStatus) }
    if {$which eq "verify"   && [array exists V] && [info exists V(onStatus)]} { set cb $V(onStatus) }
    if {$cb ne ""} { catch { {*}$cb $which $done $total } }
}

# 4 minutes of silence means the engine is gone.
proc ::cr_engine::watch_ {which} {
    variable A
    variable V
    if {$which eq "analysis"} {
        if {[info exists A(watch)]} { catch { after cancel $A(watch) } }
        set A(watch) [after 240000 [list ::cr_engine::error_ analysis "engine stopped responding"]]
    } else {
        if {[info exists V(watch)]} { catch { after cancel $V(watch) } }
        set V(watch) [after 240000 [list ::cr_engine::error_ verify "verifier stopped responding"]]
    }
}

proc ::cr_engine::error_ {which msg} {
    variable A
    variable V
    if {$which eq "analysis"} {
        catch { after cancel $A(watch) }
        catch { ::engineNoWin::closeEngine 20 }
        if {[info exists A(onError)] && $A(onError) ne ""} { catch { {*}$A(onError) $msg } }
        if {[info exists A(onDone)] && $A(onDone) ne ""} { catch { {*}$A(onDone) error } }
    } else {
        catch { after cancel $V(watch) }
        catch { ::engineNoWin::closeEngine 21 }
        if {[info exists V(onError)] && $V(onError) ne ""} { catch { {*}$V(onError) $msg } }
        if {[info exists V(onDone)] && $V(onDone) ne ""} { catch { {*}$V(onDone) error } }
    }
    return error
}

# ------------------------------------------------------------------- quick --
# One short search on an arbitrary position, for the threat probe.
# cb is called as {$cb $firstMovesOfEachLine $errorString}.
proc ::cr_engine::quick {position depth cb} {
    variable Q
    array unset Q
    array set Q [dict create cur {} ]
    set Q(position) $position
    set Q(depth) $depth
    set Q(cb) $cb
    set engine $::cr_settings::s(engine_analysis)
    if {$engine eq ""} {
        catch { {*}$cb {} "no analysis engine configured" }
        return error
    }
    if {[catch { ::engineNoWin::initEngine 22 $engine [list ::cr_engine::onQuickMsg] } err]} {
        catch { {*}$cb {} "cannot start engine '$engine': $err" }
        return error
    }
    ::engine::send 22 SetOptions [list [list MultiPV 3] [list Threads $::cr_settings::s(threads)] [list Hash $::cr_settings::s(hash_mb)]]
    catch { ::engine::send 22 Go [list $position [list [list depth $depth]]] }
    return ok
}

proc ::cr_engine::onQuickMsg {msg} {
    variable Q
    lassign $msg tag data
    switch -- $tag {
        InfoPV { ::cr_engine::collect Q $data }
        InfoBestMove {
            set lines {}
            if {[info exists Q(cur)]} {
                foreach mpv [lsort -integer [dict keys $Q(cur)]] {
                    set pv [lindex [dict get $Q(cur) $mpv] 2]
                    if {[llength $pv]} { lappend lines [lindex $pv 0] }
                }
            }
            catch { ::engineNoWin::closeEngine 22 }
            {*}$Q(cb) $lines ""
        }
        InfoDisconnected {
            catch { ::engineNoWin::closeEngine 22 }
            {*}$Q(cb) {} "engine disconnected: $data"
        }
    }
}

# ------------------------------------------------------------- cloud pre-pass --
# Lichess cloud evaluations are the community's stored Stockfish analysis: free,
# instant, and at a depth far above what this pass would reach locally (measured
# here: median depth 55 against depth 18, ~230 ms against 1-13 s per position).
# The pre-pass asks for every position first; the engine then searches only what
# the cloud does not cover. Scores come back from White's side and are converted
# to the side to move, which is the convention the analysis pass uses.

proc ::cr_engine::cloudQuery {fen cb} {
    variable CLOUD
    variable CLOUD_CACHE
    variable CLOUD_URL
    variable MULTIPV
    if {[info exists CLOUD_CACHE($fen)]} {
        set val $CLOUD_CACHE($fen)
        after 0 [list ::cr_engine::cloudDone_ $val $cb]
        return
    }
    set variant standard
    catch { if {[sc_game variant] eq "chess960"} { set variant chess960 } }
    set urlFen [string map {" " "%20"} $fen]
    set url "$CLOUD_URL?fen=$urlFen&multiPv=$MULTIPV&variant=$variant"
    if {[catch {
        set fd [open [list | curl -s --max-time 15 -H {Accept: application/json} $url] r]
        fconfigure $fd -blocking 0 -translation binary
    } err]} {
        after 0 [list ::cr_engine::cloudDone_ "" $cb]
        return
    }
    set CLOUD(fd,$fen) $fd
    set CLOUD(buf,$fen) ""
    fileevent $fd readable [list ::cr_engine::cloudData_ $fen $cb]
}

proc ::cr_engine::cloudDone_ {val cb} {
    catch { {*}$cb $val }
}

proc ::cr_engine::cloudData_ {fen cb} {
    variable CLOUD
    variable CLOUD_CACHE
    set fd $CLOUD(fd,$fen)
    if {[catch { append CLOUD(buf,$fen) [read $fd] }]} {
        catch { close $fd }
        unset -nocomplain CLOUD(fd,$fen) CLOUD(buf,$fen)
        after 0 [list ::cr_engine::cloudDone_ "" $cb]
        return
    }
    if {![eof $fd]} { return }
    fileevent $fd readable ""
    catch { close $fd }
    set raw $CLOUD(buf,$fen)
    unset -nocomplain CLOUD(fd,$fen) CLOUD(buf,$fen)
    set val [::cr_engine::cloudParse $raw $fen]
    set CLOUD_CACHE($fen) $val
    after 0 [list ::cr_engine::cloudDone_ $val $cb]
}

# raw JSON -> {multipv -> {score type pv depth}}, or "" when nothing usable.
# Lichess reports centipawns and mate distance from White's side; the engine
# layer reports them from the side to move, so Black-to-move positions negate.
proc ::cr_engine::cloudParse {raw fen} {
    if {[string first {"pvs"} $raw] < 0} { return "" }
    set depth ""
    regexp {"depth"\s*:\s*(\d+)} $raw -> depth
    if {![string is integer -strict $depth]} { return "" }
    set side [lindex [split $fen] 1]
    set sign [expr {$side eq "b" ? -1 : 1}]
    set out [dict create]
    set n 0
    foreach obj [regexp -all -inline {\{[^{}]*\}} $raw] {
        set moves "" ; set cp "" ; set mate ""
        regexp {"moves"\s*:\s*"([^"]*)"} $obj -> moves
        regexp {"cp"\s*:\s*(-?\d+)} $obj -> cp
        regexp {"mate"\s*:\s*(-?\d+)} $obj -> mate
        if {$moves eq ""}  continue
        if {$cp eq "" && $mate eq ""} continue
        incr n
        if {$mate ne ""} {
            dict set out $n [list [expr {$sign * $mate}] mate $moves $depth]
        } else {
            dict set out $n [list [expr {$sign * $cp}] cp $moves $depth]
        }
    }
    if {![dict size $out]} { return "" }
    return $out
}

# options: fens, startIndex, mode (uniform|fill), minDepth, minPv,
#          onProgress(done total), onDone(prefilled stats)
proc ::cr_engine::cloudPrefill {options} {
    variable CLOUD
    array unset CLOUD
    set fens [dict get $options fens]
    set start [dict get $options startIndex]
    set queue {}
    for {set k $start} {$k < [llength $fens]} {incr k} { lappend queue $k }
    array set CLOUD [dict create \
        queue $queue q 0 total [llength $queue] \
        prefilled {} accepted 0 misses 0 consec 0 aborted 0 \
        mode [dict get $options mode] \
        minDepth [dict get $options minDepth] minPv [dict get $options minPv] \
        fens $fens \
        onProgress [expr {[dict exists $options onProgress] ? [dict get $options onProgress] : ""}] \
        onDone [expr {[dict exists $options onDone] ? [dict get $options onDone] : ""}]]
    if {!$CLOUD(total)} { ::cr_engine::cloudFinish ; return ok }
    ::cr_engine::cloudNext
    return ok
}

proc ::cr_engine::cloudNext {} {
    variable CLOUD
    if {$CLOUD(q) >= $CLOUD(total)} { ::cr_engine::cloudFinish ; return }
    # In uniform mode a handful of early misses means the game is not covered;
    # stop paying latency for it.
    if {$CLOUD(mode) eq "uniform" && $CLOUD(consec) >= 8 && $CLOUD(accepted) == 0} {
        catch { ::cr_review::log "cloud pre-pass: 8 misses in a row, abandoning it" }
        set CLOUD(aborted) 1
        ::cr_engine::cloudFinish
        return
    }
    set k [lindex $CLOUD(queue) $CLOUD(q)]
    if {$CLOUD(onProgress) ne ""} { catch { {*}$CLOUD(onProgress) $CLOUD(q) $CLOUD(total) $CLOUD(accepted) } }
    ::cr_engine::cloudQuery [lindex $CLOUD(fens) $k] [list ::cr_engine::cloudGot $k]
}

proc ::cr_engine::cloudGot {k val} {
    variable CLOUD
    set ok 0
    if {$val ne ""} {
        set first [lindex [dict keys $val] 0]
        lassign [dict get $val $first] score type pv depth
        # A shallow entry, or one with a single PV line, cannot drive the
        # MultiPV-gap rules; search those locally instead.
        if {[string is integer -strict $depth] && $depth >= $CLOUD(minDepth) \
            && [dict size $val] >= $CLOUD(minPv)} {
            set ok 1
        }
    }
    if {$ok} {
        dict set CLOUD(prefilled) $k $val
        incr CLOUD(accepted)
        set CLOUD(consec) 0
    } else {
        incr CLOUD(misses)
        incr CLOUD(consec)
    }
    incr CLOUD(q)
    ::cr_engine::cloudNext
}

proc ::cr_engine::cloudFinish {} {
    variable CLOUD
    set total $CLOUD(total)
    set accepted $CLOUD(accepted)
    set prefilled $CLOUD(prefilled)
    set mode $CLOUD(mode)
    set aborted $CLOUD(aborted)
    if {$mode eq "uniform" && ($accepted < $total || $aborted)} {
        # A game judged from two sources has two baselines, and a cp loss across
        # them is not a comparison. When the cloud cannot cover the whole game,
        # search the whole game.
        catch { ::cr_review::log "cloud pre-pass: $accepted/$total usable (aborted=$aborted), uniform mode -> full local pass" }
        set prefilled {}
    } else {
        catch { ::cr_review::log "cloud pre-pass: $accepted/$total usable in $mode mode" }
    }
    set stats [dict create total $total accepted $accepted aborted $aborted]
    set cb $CLOUD(onDone)
    array unset CLOUD
    if {$cb ne ""} { catch { {*}$cb $prefilled $stats } }
}
