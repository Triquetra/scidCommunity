# cr_settings.tcl -- persistent settings for the review plugin.
# Stored next to the plugin: <scidUserDir>/plugins/cr_settings.dat

namespace eval ::cr_settings {
    variable s
    array set s {
        engine_analysis ""  engine_verify ""  depth 18
        threads 8  hash_mb 1024  pv_moves 5  pv_variation 1  skip_book 1
        verify_mode candidates
        book_mode book  book_file ""  book_plies 12  book_migrated 0
        cloud_mode uniform  cloud_min_depth 18  cloud_min_pv 3
        tree_stats 0
        comment_all 0  write_eval 1  opponent_rd 100
        llm_enabled 1  api_url "https://ollama.com"  api_key ""  model ""
        prose_lang English
        phase_prose 1
    }
    variable file ""
}

proc ::cr_settings::path {} {
    variable file
    if {$file eq ""} {
        if {[info exists ::scidUserDir]} {
            set dir [file join $::scidUserDir plugins]
        } else {
            # fallback: the folder the plugin itself lives in
            set dir [file dirname [info script]]
        }
        catch { file mkdir $dir }
        set file [file join $dir cr_settings.dat]
    }
    return $file
}

# The opening book used for book detection. An explicit path wins; otherwise
# the first book scid ships with is used. Returns "" when nothing is readable,
# which makes the caller fall back to the ECO probe.
proc ::cr_settings::bookFile {} {
    variable s
    if {$s(book_file) ne "" && [file readable $s(book_file)]} {
        return $s(book_file)
    }
    if {[info exists ::scidBooksDir] && [file isdirectory $::scidBooksDir]} {
        foreach name {gm2600 varied Elo2400 Performance} {
            set f [file join $::scidBooksDir $name.bin]
            if {[file readable $f]} { return $f }
        }
        set found ""
        foreach f [lsort [glob -nocomplain -directory $::scidBooksDir *.bin]] {
            if {[file readable $f]} { set found $f ; break }
        }
        if {$found ne ""} { return $found }
    }
    return ""
}

proc ::cr_settings::load {} {
    variable s
    set f [path]
    if {![file exists $f]} {
        ::cr_settings::pickDefaults
        return
    }
    set fp [open $f r]
    while {[gets $fp line] >= 0} {
        set line [string trim $line]
        if {$line eq "" || [string index $line 0] eq "#"} continue
        if {[catch {lassign $line k v}]} continue
        if {[info exists s($k)]} { set s($k) $v }
    }
    close $fp
    # a hand-edited file must not brick the review: depth has no maximum, but it
    # does have to be a positive integer
    if {![string is integer -strict $s(depth)] || $s(depth) < 1} { set s(depth) 18 }
    foreach {k d} {cloud_min_depth 18 cloud_min_pv 3 book_plies 12} {
        if {![string is integer -strict $s($k)] || $s($k) < 0} { set s($k) $d }
    }
    # One-time move from the ECO-only boundary to the opening-book probe. A
    # settings file written before the book probe existed says "eco"; upgrade it
    # once so the improvement is actually on, and only when a book resolves.
    if {!$s(book_migrated)} {
        set s(book_migrated) 1
        if {$s(book_mode) eq "eco" && [::cr_settings::bookFile] ne ""} {
            set s(book_mode) book
        }
    }
    if {$s(engine_analysis) eq ""} { ::cr_settings::pickDefaults }
}

proc ::cr_settings::save {} {
    variable s
    set f [path]
    set fp [open $f w]
    foreach k [lsort [array names s]] { puts $fp [list $k $s($k)] }
    close $fp
}

# Default to the first two *different* UCI engines scid knows about.
proc ::cr_settings::pickDefaults {} {
    variable s
    set names {}
    catch { set names [::enginecfg::names] }
    set names [lsort $names]
    if {$s(engine_analysis) eq ""} {
        set s(engine_analysis) [expr {[llength $names] ? [lindex $names 0] : ""}]
        # prefer Stockfish for the analysis pass when it is installed
        foreach n $names { if {[string match -nocase "*stockfish*" $n]} { set s(engine_analysis) $n ; break } }
    }
    if {$s(engine_verify) eq ""} {
        foreach n $names { if {$n ne $s(engine_analysis)} { set s(engine_verify) $n ; break } }
    }
}
