########################################################################
### The engine pass behind Game Review and Move Comment.
###
### The pass runs on its own engine connection (id 20) so it never disturbs the
### analysis window's search: changing MultiPV on a window's engine restarts what
### the user is watching (::enginewin::changeOption), and a review that borrowed
### that connection would do the same.
###
### The driver is deliberately dumb about positions: the caller hands it
### {ply positionSpec} pairs, the same shape ::engine::send Go takes, because
### turning a game into position specs needs the game commands and this module
### must stay testable without them.

namespace eval reviewdriver {}

variable job
variable seq 0

set ::reviewdriver::ENGINE_ID 20

proc ::reviewdriver::start {enginecfg positions mpv depth onprogress ondone} {
    variable job
    variable seq
    set id $::reviewdriver::ENGINE_ID
    if {[info exists ::engconn(channel_$id)]} {
        error "engine $id is already running a pass"
    }
    incr seq
    set token "pass$seq"
    set job($token) [dict create \
        id $id enginecfg $enginecfg positions $positions index -1 \
        mpv $mpv depth $depth results {} lines {} configured 0 \
        stopped 0 onprogress $onprogress ondone $ondone]
    set exe [lindex $enginecfg 1]
    set args [lindex $enginecfg 2]
    ::engine::setLogCmd $id {}
    if {[catch {
        ::engine::connect $id [list ::reviewdriver::callback $token] $exe {*}$args uci
    } err]} {
        unset -nocomplain job($token)
        error $err
    }
    return $token
}

# Stop a pass: no further positions are started and the engine is closed.
proc ::reviewdriver::stop {token} {
    variable job
    if {![info exists job($token)]} {
        return 0
    }
    set id [dict get $job($token) id]
    unset job($token)
    catch { ::engine::send $id StopGo }
    catch { ::engine::close $id }
    return 1
}

# The engine messages for a pass.
proc ::reviewdriver::callback {token msg} {
    variable job
    if {![info exists job($token)]} {
        return
    }
    lassign $msg msgType msgData
    switch -- $msgType {
        "InfoConfig" {
            # SetOptions answers with another InfoConfig: configure once.
            if {[dict get $job($token) configured]} {
                return
            }
            dict set job($token) configured 1
            ::reviewdriver::configure $token
            ::reviewdriver::next $token
        }
        "InfoPV" {
            ::reviewdriver::collect $token $msgData
        }
        "InfoBestMove" {
            ::reviewdriver::next $token
        }
    }
}

proc ::reviewdriver::configure {token} {
    variable job
    set id [dict get $job($token) id]
    set opts [list [list MultiPV [dict get $job($token) mpv]]]
    set defaults [::review::engineDefaults [dict get $job($token) enginecfg]]
    foreach key {threads hash} {
        set value [dict get $defaults $key]
        if {$value ne ""} {
            lappend opts [list [expr {$key eq "threads" ? "Threads" : "Hash"}] $value]
        }
    }
    ::engine::send $id SetOptions $opts
}

# Keep the deepest line seen for each MultiPV slot of the current position.
proc ::reviewdriver::collect {token msgData} {
    variable job
    lassign $msgData multipv depth seldepth nodes nps hashfull tbhits time \
        score score_type score_wdl pv
    if {$multipv eq "" || $score eq ""} {
        return
    }
    set lines [dict get $job($token) lines]
    if {[dict exists $lines $multipv] && [lindex [dict get $lines $multipv] 0] >= $depth} {
        return
    }
    dict set lines $multipv [list $depth $score $score_type $pv]
    dict set job($token) lines $lines
}

proc ::reviewdriver::next {token} {
    variable job
    if {![info exists job($token)]} {
        return
    }
    set j $job($token)
    set positions [dict get $j positions]
    set index [dict get $j index]
    if {$index >= 0} {
        # The position we were searching has finished: keep what it found.
        lassign [lindex $positions $index] ply spec
        set lines [dict get $j lines]
        set results [dict get $j results]
        dict set results $ply $lines
        dict set job($token) results $results
        dict set job($token) lines {}
        if {[dict get $j onprogress] ne ""} {
            catch { {*}[dict get $j onprogress] [expr {$index + 1}] [llength $positions] $ply $lines }
        }
    }
    incr index
    if {$index >= [llength $positions]} {
        ::reviewdriver::finish $token
        return
    }
    dict set job($token) index $index
    dict set job($token) lines {}
    lassign [lindex $positions $index] ply spec
    set id [dict get $j id]
    ::engine::send $id Go [list $spec [list depth [dict get $j depth]]]
}

proc ::reviewdriver::finish {token} {
    variable job
    if {![info exists job($token)]} {
        return
    }
    set j $job($token)
    set id [dict get $j id]
    set results [dict get $j results]
    set done [dict get $j ondone]
    unset job($token)
    catch { ::engine::close $id }
    if {$done ne ""} {
        catch { {*}$done $results }
    }
    return $results
}
