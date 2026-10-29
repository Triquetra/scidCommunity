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
###
### onprogress {done total ply lines} reports each finished position, and ondone
### {results} fires exactly once per pass: on the last reply, or when the engine
### is lost. A results dict with fewer plies than the positions handed in is how a
### pass that was cut short is reported.

namespace eval reviewdriver {}

variable job
variable seq 0

set ::reviewdriver::ENGINE_ID 20

# Whether an engine window may take this connection id. Window ids come from the
# same pool as every other engine connection, and ::engine::connect closes
# whatever already holds the id it is given, so a window opened on the pass's id
# would take the pass's engine - and the pass would take the window's.
# ::enginewin::Open asks this before it takes an id.
proc ::reviewdriver::reservedId {id} {
    return [expr {[string equal $id $::reviewdriver::ENGINE_ID]}]
}

proc ::reviewdriver::start {enginecfg positions mpv depth onprogress ondone} {
    variable job
    variable seq
    set id $::reviewdriver::ENGINE_ID
    if {[::reviewdriver::busy $id]} {
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
        # The preset's args go in as one element, the way ::enginewin and
        # ::engineNoWin pass them: ::engine::connect takes the protocol from its
        # last positional, so splatting here either swallows "uci" into the
        # engine's own argv (Stockfish runs it as a command and exits) or gives
        # connect more positionals than it has parameters.
        ::engine::connect $id [list ::reviewdriver::callback $token] $exe $args uci
    } err]} {
        unset -nocomplain job($token)
        error $err
    }
    return $token
}

# Is a pass using this engine id? A finished pass leaves its connection open
# until the queued close runs, so the id can be occupied with nothing to run.
proc ::reviewdriver::busy {id} {
    variable job
    foreach token [array names job] {
        if {[dict get $job($token) id] eq $id} {
            return 1
        }
    }
    return 0
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
    ::reviewdriver::closeSoon $id
    return 1
}

# Nothing may close a connection from inside an engine reply. ::engine::close runs
# ::engine::destroy_, which unsets the arrays ::engine::reply walks *after* the
# callback returns, so a close in finish, or in an onprogress handler that stops the
# pass, throws on every completed pass. Queue the close instead, and take the channel
# it was queued for: a pass that starts in the meantime has its own connection and
# must keep it.
proc ::reviewdriver::closeSoon {id} {
    set channel ""
    catch { set channel $::engconn(channel_$id) }
    if {$channel eq ""} {
        return
    }
    after idle [list ::reviewdriver::closeConn $id $channel]
}

proc ::reviewdriver::closeConn {id channel} {
    if {![info exists ::engconn(channel_$id)]} {
        return
    }
    if {$::engconn(channel_$id) ne $channel} {
        return
    }
    catch { ::engine::close $id }
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
        "InfoDisconnected" {
            # The process died mid-pass: its connection is already gone, and the
            # caller would otherwise wait forever for a pass nobody will finish.
            ::reviewdriver::lost $token
        }
    }
}

proc ::reviewdriver::configure {token} {
    variable job
    set id [dict get $job($token) id]
    set opts [list [list MultiPV [dict get $job($token) mpv]]]
    # ::review::effective, not the preset itself: a pass is a second engine, and
    # that is where the ceiling on the threads and hash it may take lives. Ask
    # the preset here and a 110 GB transposition table is allocated twice.
    set eff [::review::effective [dict get $job($token) enginecfg]]
    foreach key {threads hash} {
        set value [dict get $eff $key]
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
            # The handler may have stopped the pass. Then there is no job to
            # advance and no engine left to search the next position.
            if {![info exists job($token)]} {
                return
            }
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
    # finish runs inside the last InfoBestMove reply, so the close is queued rather
    # than done here; ondone still sees the whole result.
    ::reviewdriver::closeSoon $id
    if {$done ne ""} {
        catch { {*}$done $results }
    }
    return $results
}

# The engine is gone: report what finished and forget the pass. Nothing is closed,
# because there is nothing left to close.
proc ::reviewdriver::lost {token} {
    variable job
    if {![info exists job($token)]} {
        return
    }
    set j $job($token)
    unset job($token)
    set results [dict get $j results]
    set done [dict get $j ondone]
    if {$done ne ""} {
        catch { {*}$done $results }
    }
    return $results
}
