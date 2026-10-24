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
    set A(work) [expr {$A(total) - $start}]
    set A(onStatus) [expr {[dict exists $options onStatus] ? [dict get $options onStatus] : ""}]
    set A(onDone) [expr {[dict exists $options onDone] ? [dict get $options onDone] : ""}]
    set A(onError) [expr {[dict exists $options onError] ? [dict get $options onError] : ""}]

    if {$A(work) < 1} {
        # nothing to search (whole game inside the book): report done at once
        if {$A(onDone) ne ""} { {*}$A(onDone) ok }
        return ok
    }
    if {[catch {
        ::engineNoWin::initEngine 20 $A(engine1) [list ::cr_engine::onAnalysisMsg]
    } err]} {
        return [error_ analysis "cannot start engine '$A(engine1)': $err"]
    }
    catch { ::cr_review::log "engine 20 connected: $A(engine1), $A(total) positions" }
    ::engine::send 20 SetOptions [list [list MultiPV $MULTIPV] [list Threads $::cr_settings::s(threads)] [list Hash $::cr_settings::s(hash_mb)]]
    ::cr_engine::status_ analysis 0 $A(work)
    ::cr_engine::watch_ analysis
    ::cr_engine::nextPos
    return ok
}

proc ::cr_engine::nextPos {} {
    variable A
    if {$A(i) >= $A(total)} {
        catch { ::engineNoWin::closeEngine 20 }
        catch { after cancel $A(watch) }
        if {$A(onDone) ne ""} { {*}$A(onDone) ok }
        return
    }
    catch { ::engine::send 20 Go [list [lindex $A(positions) $A(i)] [list [list depth $A(depth)]]] }
}

proc ::cr_engine::onAnalysisMsg {msg} {
    variable A
    if {![array exists A] || ![info exists A(i)]} { return }
    ::cr_engine::watch_ analysis
    lassign $msg tag data
    switch -- $tag {
        InfoPV { ::cr_engine::collect A $data }
        InfoBestMove {
            set A(evals,$A(i)) [expr {[info exists A(cur)] ? $A(cur) : [dict create]}]
            catch { unset A(cur) }
            incr A(i)
            set done [expr {$A(i) - $A(start)}]
            if {$done == 1 || $done % 10 == 0 || $A(i) >= $A(total)} {
                catch { ::cr_review::log "engine 20: $done/$A(work) positions (ply $A(i))" }
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
