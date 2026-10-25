# cr_llm.tcl -- Ollama Cloud prose layer.
#
# The model never decides anything: every label, eval and best move is computed
# locally by cr_classify, and the model is handed those facts and asked for
# prose. Works against any OpenAI-ish /api/chat host that accepts the native
# Ollama shape; the API key is only sent when one is configured (Ollama Cloud
# requires it, a localhost Ollama ignores it).

namespace eval ::cr_llm {
    variable J           ;# job queue
    array set J {}
    variable busy 0
}

proc ::cr_llm::jsonEscape {s} {
    set out ""
    foreach ch [split $s ""] {
        switch -- $ch {
            "\\" { append out "\\\\" }
            "\"" { append out "\\\"" }
            "\n" { append out "\\n" }
            "\r" { append out "\\r" }
            "\t" { append out "\\t" }
            default { append out $ch }
        }
    }
    return $out
}

proc ::cr_llm::body {prompt {maxTokens 300}} {
    set m [::cr_llm::jsonEscape $prompt]
    return "{\"model\":\"[::cr_llm::jsonEscape $::cr_settings::s(model)]\",\"messages\":\[{\"role\":\"user\",\"content\":\"$m\"}\],\"stream\":false,\"think\":false,\"options\":{\"temperature\":0.3,\"num_predict\":$maxTokens}}"
}

# Pull message.content out of the JSON reply. Ollama streams NDJSON only when
# stream=true; with stream=false it is one object, but tolerant parsing costs
# nothing here.
proc ::cr_llm::extractContent {json} {
    set idx [string first "\"content\":\"" $json]
    if {$idx < 0} { return "" }
    set i [expr {$idx + 11}]
    set out ""
    set n [string length $json]
    while {$i < $n} {
        set ch [string index $json $i]
        if {$ch eq "\\"} {
            set nx [string index $json [expr {$i + 1}]]
            switch -- $nx {
                n { append out "\n" }
                t { append out "\t" }
                r { append out "" }
                "\"" { append out "\"" }
                "\\" { append out "\\" }
                "/" { append out "/" }
                u {
                    set hex [string range $json [expr {$i + 2}] [expr {$i + 5}]]
                    if {[string is xdigit -strict $hex]} {
                        append out [format %c [expr {[scan $hex %x]}]]
                        incr i 4
                    }
                }
                default { append out $nx }
            }
            incr i 2
            continue
        }
        if {$ch eq "\""} { break }
        append out $ch
        incr i
    }
    return $out
}

proc ::cr_llm::ask {prompt cb {maxTokens 300}} {
    variable J
    if {$::cr_settings::s(model) eq ""} {
        catch { {*}$cb "" "no model configured" }
        return
    }
    set url "[string trimright $::cr_settings::s(api_url) /]/api/chat"
    set cmd [list | curl -s --max-time 180 -H "Content-Type: application/json"]
    if {$::cr_settings::s(api_key) ne ""} {
        lappend cmd -H "Authorization: Bearer $::cr_settings::s(api_key)"
    }
    lappend cmd -d [::cr_llm::body $prompt $maxTokens] $url
    if {[catch {
        set fd [open $cmd r]
        fconfigure $fd -blocking 0 -translation binary
    } err]} {
        catch { {*}$cb "" "cannot run curl: $err" }
        return
    }
    set J(buf,$fd) ""
    set J(cb,$fd) $cb
    fileevent $fd readable [list ::cr_llm::onData $fd]
}

proc ::cr_llm::onData {fd} {
    variable J
    if {[catch { append J(buf,$fd) [read $fd] }]} {
        catch { close $fd }
        set cb $J(cb,$fd)
        unset -nocomplain J(buf,$fd) J(cb,$fd)
        catch { {*}$cb "" "read failed" }
        return
    }
    if {[eof $fd]} {
        fileevent $fd readable ""
        catch { close $fd }
        set raw $J(buf,$fd)
        set cb $J(cb,$fd)
        unset -nocomplain J(buf,$fd) J(cb,$fd)
        set text [::cr_llm::extractContent $raw]
        if {$text eq ""} {
            catch { {*}$cb "" "empty reply (check model name, key and endpoint)" }
        } else {
            catch { {*}$cb [string trim $text] "" }
        }
    }
}

# ---- prompts ---------------------------------------------------------------

proc ::cr_llm::fmtEval {cp} {
    return [::cr_review::fmtEval $cp]
}

# `m` is a full move record (played/best_uci/fens/candidates). The chess
# content comes from ::crfacts; the model writes prose on top of it and is
# told, in as many words, not to recite the numbers.
proc ::cr_llm::momentPrompt {m} {
    set facts [::crfacts::forMove $m]
    set label [dict get $m classification]
    set banned {}
    foreach w {inaccuracy mistake blunder miss} {
        if {$w ne $label} { lappend banned "\"$w\"" }
    }
    set banned [join $banned {, }]
    return "You are a chess coach writing one annotation for a scoresheet.
Explain in plain English WHY this move is judged a $label: what it fails to do, what it allows, and what the better move achieves. Write for a club player reading the game later.
Rules:
- Use only the FACTS below. Never name a piece, square or move that is not in FACTS.
- FACTS lists every piece on the board: a piece it does not list is not there, so do not mention it.
- Do not describe what a line shows beyond the moves printed in it, and do not claim a move left something untouched or unprotected unless FACTS says so.
- Never mention castling, en passant, repetition or the fifty-move rule beyond what the corresponding FACTS lines say.
- FACTS includes the engine's line; you may refer to moves in that line (and only those) to show what the better move achieves.
- Do NOT mention centipawns, evaluations, win percentages, accuracy, or any number at all. The reader already sees the score next to the move.
- Do not repeat the move number and do not use the words $banned.
- No lists, no headings, no preamble. At most two sentences, plain prose.
FACTS:
$facts"
}


# Typographic characters in model output are mapped back to ASCII before they
# reach the PGN: scid reads plugin sources and comments with the host codepage,
# so a UTF-8 em dash arrives as mojibake ("a-hat"). Accented letters are left
# alone - those are real text, not punctuation.
proc ::cr_llm::asciiSafe {text} {
    # character codes, not literals: the source stays pure ASCII, which is the
    # whole point of this function
    set q [format %c 34]
    set map [list [format %c 8212] - [format %c 8211] - [format %c 8216] ' \
        [format %c 8217] ' [format %c 8220] $q [format %c 8221] $q \
        [format %c 8230] ... [format %c 160] { }]
    return [string map $map $text]
}

# Models write SAN sloppily: capitalised pawn moves (A6), lowercase pieces (nf3)
# and markdown emphasis. Left alone they land in the PGN as written. One pass
# per letter, never a single alternation: a combined pattern with a backreference
# is the kind of thing that quietly rewrites text mid-word.
proc ::cr_llm::sanFix {text} {
    set text [regsub -all {\*\*([^*]+)\*\*} $text {\1}]
    set text [regsub -all {\*([^*]+)\*} $text {\1}]
    foreach cap {A B C D E F G H} {
        set low [string tolower $cap]
        set rep "\\1${low}\\2"
        set text [regsub -all "(^|\[^a-zA-Z\])${cap}(\[1-8\])" $text $rep]
    }
    foreach l {k q r b n} {
        set U [string toupper $l]
        set rep "\\1${U}\\2"
        set text [regsub -all "(^|\[^a-zA-Z\])${l}(\[a-h\]\[1-8\])" $text $rep]
        set text [regsub -all "(^|\[^a-zA-Z\])${l}(x\[a-h\]\[1-8\])" $text $rep]
    }
    return $text
}

# Everything model prose passes through before it is written anywhere.
proc ::cr_llm::cleanProse {text} {
    return [::cr_llm::sanFix [::cr_llm::asciiSafe $text]]
}

# The comment written at the end of a phase: a marker the next review can find
# and replace, the phase's own figures (the reader should not have to open the
# report to know what the paragraph is about), then the prose.
proc ::cr_llm::phaseBlock {ph st text} {
    set block "\[Phase $ph\] plies [dict get $st from_ply]-[dict get $st to_ply] - "
    append block [format "accuracy W %.1f%% B %.1f%%, acpl W %d B %d." \
        [dict get $st accuracy_white] [dict get $st accuracy_black] \
        [dict get $st acpl_white] [dict get $st acpl_black]]
    set prose [string trim [::cr_llm::cleanProse $text]]
    if {$prose ne ""} { append block "\n" $prose }
    return $block
}

# ---- game summary ----------------------------------------------------------
#
# Colour-neutral, and built from the same facts Patzer uses: the turning point,
# each side's costliest moves and best finds, the gifts and how they were
# answered, and each side's weakest phase. The model writes the closing note;
# it never re-states the numbers printed beside the moves.

# Two yardsticks, because they answer different questions.
#
# _cpSwing: how many centipawns the move cost the mover. Used to pick THE
# turning point, where the size of the error itself is what matters.
#
# _winSwing: how many win-percentage points it cost. Used to rank errors for a
# player's attention, because losing 500 cp while already winning by 1300
# changes nothing, while losing 9 cp in a level position can decide a game.
proc ::cr_llm::_cpSwing {m} {
    if {![dict exists $m player_before] || ![dict exists $m player_after]} { return 0.0 }
    return [expr {[dict get $m player_before] - [dict get $m player_after]}]
}

proc ::cr_llm::_winSwing {m} {
    if {![dict exists $m player_before] || ![dict exists $m player_after]} { return 0.0 }
    set wb [::crclass::cpToWinPct [dict get $m player_before]]
    set wa [::crclass::cpToWinPct [dict get $m player_after]]
    return [expr {$wb - $wa}]
}

proc ::cr_llm::_swing {m} { return [_cpSwing $m] }


# Significance for coaching: win-chance points lost, weighted by how much the
# game was still in doubt. Losing 590 cp at +13 costs almost no win chance and
# teaches nothing; being 0.9 pawns worse off in a level position does.
proc ::cr_llm::contestion {evalWhite} {
    set a [expr {abs($evalWhite)}]
    if {$a <= 200} { return 1.0 }
    if {$a >= 800} { return 0.0 }
    return [expr {(800 - $a) / 600.0}]
}

proc ::cr_llm::_significance {m} {
    set sw [_winSwing $m]
    set ev [expr {[dict exists $m eval_before_cp] ? [dict get $m eval_before_cp] : 0}]
    return [expr {$sw * [contestion $ev]}]
}

proc ::cr_llm::_bySignificance {moves limit} {
    set sorted [lsort -command {apply {{a b} {
        set sa [::cr_llm::_significance $a] ; set sb [::cr_llm::_significance $b]
        if {$sa > $sb} { return -1 }
        if {$sa < $sb} { return 1 }
        return 0
    }}} $moves]
    return [lrange $sorted 0 [expr {$limit - 1}]]
}

proc ::cr_llm::_byWinSwing {moves limit} {
    set sorted [lsort -command {apply {{a b} {
        set sa [::cr_llm::_winSwing $a] ; set sb [::cr_llm::_winSwing $b]
        if {$sa > $sb} { return -1 }
        if {$sa < $sb} { return 1 }
        return 0
    }}} $moves]
    return [lrange $sorted 0 [expr {$limit - 1}]]
}

proc ::cr_llm::_bySwing {moves limit} {
    set sorted [lsort -command {apply {{a b} {
        set sa [::cr_llm::_swing $a] ; set sb [::cr_llm::_swing $b]
        if {$sa > $sb} { return -1 }
        if {$sa < $sb} { return 1 }
        return 0
    }}} $moves]
    return [lrange $sorted 0 [expr {$limit - 1}]]
}


# Where the game was decided, without any centipawn constant.
#
# The move that matters is the one after which the loser never got back into
# the game: walk back from the end while the losing side's win chance stays
# below the competitive line, and the first ply of that final run is the point
# of no return. Win chance is bounded and normalised, so the same rule reads
# the same way in a 20-move miniature and a 90-move grind, which a fixed
# centipawn cut-off cannot.
proc ::cr_llm::turningMove {moves} {
    set LAST ""
    foreach m $moves {
        if {[dict exists $m unsearched]} continue
        if {![dict exists $m eval_after_cp]} continue
        set LAST $m
    }
    if {$LAST eq ""} { return "" }
    set final [dict get $LAST eval_after_cp]
    if {$final == 0} { return "" }
    # Win chance below this is no longer competitive. Ten percent is the
    # conventional "practically lost" line, and it is a property of the game,
    # not of the engine's centipawn scale.
    set LINE 10.0
    # the loser is whoever the final evaluation is against
    set loser [expr {$final > 0 ? "black" : "white"}]
    set seq {}
    foreach m $moves {
        if {[dict exists $m unsearched]} continue
        if {![dict exists $m eval_after_cp]} continue
        set ev [dict get $m eval_after_cp]
        set wp [expr {$loser eq "white" ? [::crclass::cpToWinPct $ev] : [::crclass::cpToWinPct [expr {-$ev}]]}]
        lappend seq [list [dict get $m ply] $wp $m]
    }
    set n [llength $seq]
    set start $n
    for {set k [expr {$n - 1}]} {$k >= 0} {incr k -1} {
        lassign [lindex $seq $k] ply wp m
        if {$wp < $LINE} { set start $k } else { break }
    }
    if {$start < $n} { return [lindex $seq $start 2] }
    return ""
}

proc ::cr_llm::punishmentFacts {turn} {
    set out {}
    if {$turn eq ""} { return $out }
    # What actually punished the move: the reply that followed, whether it
    # attacked the piece that had just moved, and how the punished side answered.
    # This is the evidence for the judgement the LEVEL line makes - the engine's
    # alternative is NOT the lesson, and claiming a missed capture was "forcing"
    # when it was not misleads the coach.
    
        set tply [dict get $turn ply]
        set td [::crfacts::describeMove [dict get $turn fen_before] [dict get $turn played]]
        set tside [expr {[dict get $td side] eq "White" ? "w" : "b"}]
        set tpiece [dict get $td piece]
        set reply [::cr_review::moveByPly [expr {$tply + 1}]]
        if {$reply ne ""} {
            lappend out "the punishment: [::crfacts::phaseMoveLine $reply]"
            if {[catch {
                set rpos [::crboard::makeMove [::crboard::fromFen [dict get $reply fen_before]] [dict get $reply played]]
                set tsq [dict get $td to]
                # who attacks the punished piece? the other side, obviously
                set hits [::crfacts::attackersOf $rpos [::crboard::sqIndex $tsq] [::crfacts::other $tside]]
            }]} { set hits {} }
            if {[llength $hits]} {
                lappend out "the punishment attacks the $tpiece on $tsq"
            }
            set answer [::cr_review::moveByPly [expr {$tply + 2}]]
            if {$answer ne ""} {
                # A reply that cost almost nothing right after a huge loss is a
                # consequence of the blunder, not an error of its own: label it
                # as forced instead of repeating a judgement it did not earn.
                set prevLoss [expr {[dict exists $turn cp_loss] ? [dict get $turn cp_loss] : 0}]
                set ansLoss [expr {[dict exists $answer cp_loss] ? [dict get $answer cp_loss] : 0}]
                if {$prevLoss >= 200 && $ansLoss <= 50} {
                    set txt [::crfacts::phaseMoveLine $answer -noclass]
                    lappend out "the punished side answered with: $txt, which was forced by the earlier mistake"
                } else {
                    lappend out "the punished side answered with: [::crfacts::phaseMoveLine $answer]"
                }
            }
            set after [::cr_review::moveByPly [expr {$tply + 3}]]
            if {$after ne ""} {
                lappend out "and then: [::crfacts::phaseMoveLine $after]"
            }
            # The net exchange is what the summary's first sentence is about.
            if {$answer ne "" && $after ne ""} {
                if {[catch {
                    set da [::crfacts::describeMove [dict get $answer fen_before] [dict get $answer played]]
                    set df [::crfacts::describeMove [dict get $after fen_before] [dict get $after played]]
                    set took [dict get $da capture]
                    set lost [dict get $df capture]
                }]} { set took "" ; set lost "" }
                if {$took ne "" && $lost ne ""} {
                    set who [expr {$tside eq "w" ? "White" : "Black"}]
                    lappend out "netted out: $who's $lost went for a $took"
                }
            }
        }
    
    return $out
}


# Strength in words, from the game's own accuracy estimate. LEVEL is about the
# players' level, so it needs a level to talk about - and the number itself
# stays in the header where it belongs.

# Where the game stood, in words, from White's evaluation in centipawns.
proc ::cr_llm::balanceWord {cpWhite} {
    set a [expr {abs($cpWhite)}]
    if {$a < 100} { return "level" }
    set who [expr {$cpWhite > 0 ? "White" : "Black"}]
    if {$a < 300} { return "$who somewhat better" }
    if {$a < 600} { return "$who clearly better" }
    if {$a < 1000} { return "$who winning" }
    return "$who completely winning"
}

proc ::cr_llm::levelBand {elo} {
    if {$elo <= 0} { return "" }
    if {$elo < 800}  { return "beginner" }
    if {$elo < 1100} { return "improver" }
    if {$elo < 1400} { return "club player" }
    if {$elo < 1700} { return "strong club player" }
    if {$elo < 2000} { return "tournament player" }
    return "expert"
}

proc ::cr_llm::summaryFacts {} {
    upvar #0 ::cr_review::R R
    set lines {}
    set bw [levelBand [expr {[info exists R(elo,white)] ? $R(elo,white) : 0}]]
    set bb [levelBand [expr {[info exists R(elo,black)] ? $R(elo,black) : 0}]]
    if {$bw ne "" && $bb ne ""} {
        lappend lines "measured level: White $bw, Black $bb"
        lappend lines "the weaker side: [expr {$R(elo,white) >= $R(elo,black) ? "Black" : "White"}]"
    }

    set res ""
    catch { set res [string trim [sc_game tags get Result]] }
    if {$res eq "1-0"} {
        lappend lines "result: White won"
    } elseif {$res eq "0-1"} {
        lappend lines "result: Black won"
    } elseif {$res eq "1/2-1/2"} {
        lappend lines "result: drawn"
    }
    # The Opening tag names the opening. ECO is a code, and Event/Site are the
    # venue: "Olathe C21" is not an opening, so neither is ever used as a name.
    set eco ""
    catch { set eco [string trim [sc_game tags get ECO]] }
    set opn ""
    catch { set opn [string trim [sc_game tags get Opening]] }
    # The ECO code already sits in the PGN header, so it is never repeated in
    # the prose - and it is not a name, so it is never used as one either. When
    # the header carries only a code, the ECO table can still supply the name;
    # that is a derived name, not a substitute for one.
    if {$opn eq "" && $eco ne ""} {
        catch { set opn [::crfacts::ecoName $eco] }
    }
    if {$opn ne ""} {
        lappend lines "opening: $opn"
    } else {
        lappend lines "opening: no name recorded"
    }
    # Opt-in database line: the position occurred elsewhere and how it scored.
    if {[info exists ::cr_review::R(treeLine)] && $::cr_review::R(treeLine) ne ""} {
        lappend lines "database: $::cr_review::R(treeLine)"
    }

    set decided ""
    foreach m $R(movesOut) {
        if {[dict exists $m unsearched]} continue
        if {[dict exists $m eval_after_cp] && abs([dict get $m eval_after_cp]) >= 800} {
            set decided [dict get $m ply]
            break
        }
    }
    if {$decided ne ""} {
        set dm [expr {($decided + 1) / 2}]
        lappend lines "the game was decided by move $dm, after which the result was no longer in doubt"
    }

    set bad {}
    set whiteCostly {}
    set blackCostly {}
    set gains {}
    foreach m $R(movesOut) {
        if {[dict exists $m unsearched]} continue
        set cls [dict get $m classification]
        # ply parity is authoritative; the record's side field is a convenience
        set side [expr {[dict get $m ply] % 2 ? "white" : "black"}]
        if {[lsearch -exact {inaccuracy mistake miss blunder} $cls] >= 0} {
            lappend bad $m
            if {$side eq "white"} { lappend whiteCostly $m } else { lappend blackCostly $m }
        } elseif {[lsearch -exact {book forced} $cls] < 0} {
            # Same test as the errors: a good move belongs in a summary only if
            # it changed the result. Castling in a position already won is a
            # move a player should make, not news.
            set gain [expr {-[::cr_llm::_winSwing $m]}]
            if {$gain >= 10.0} { lappend gains [list $gain $side $m] }
        }
    }
    set whiteBest {}
    set blackBest {}
    foreach e [lsort -command {apply {{a b} {
        set sa [lindex $a 0] ; set sb [lindex $b 0]
        if {$sa > $sb} { return -1 }
        if {$sa < $sb} { return 1 }
        return 0
    }}} $gains] {
        lassign $e gain side m
        if {$side eq "white"} {
            if {[llength $whiteBest] < 2} { lappend whiteBest $m }
        } else {
            if {[llength $blackBest] < 2} { lappend blackBest $m }
        }
    }

    # The turning point is the move after which the loser never recovered, not
    # the biggest error on a centipawn yardstick: 500 cp means "lost" in one
    # game and "still fighting" in another.
    set turn [turningMove $R(movesOut)]
    if {$turn eq ""} {
        # nobody ever crossed the line (a draw, or a game decided on the clock):
        # fall back to the largest error, weighted for significance.
        foreach m [_bySignificance $bad 1] { set turn $m }
    }
    if {$turn ne ""} {
        lappend lines "the game turned here: [::crfacts::phaseMoveLine $turn]"
    }
    foreach l [punishmentFacts $turn] { lappend lines $l }

    foreach {who lst} [list White $whiteCostly Black $blackCostly] {
        # Only errors that changed the result belong in a summary: an inaccuracy
        # in a quiet position is coaching material for the phase, not the story
        # of the game. The turning point is already stated above, so it is not
        # repeated here either.
        set picked {}
        foreach m [_bySwing $lst 8] {
            if {[_significance $m] < 0.5} continue
            if {[_winSwing $m] < 10.0} continue
            if {$turn ne "" && [dict get $m ply] == [dict get $turn ply]} continue
            lappend picked $m
            if {[llength $picked] >= 2} break
        }
        if {![llength $picked]} continue
        set out {}
        foreach m $picked { lappend out [::crfacts::phaseMoveLine $m] }
        lappend lines "errors by $who that changed the result: [join $out {; }]"
    }
    foreach {who lst} [list White $whiteBest Black $blackBest] {
        set picked [lrange $lst 0 1]
        if {![llength $picked]} continue
        set out {}
        foreach m $picked { lappend out [::crfacts::phaseMoveLine $m] }
        lappend lines "$who's best moves: [join $out {; }]"
    }

    # Gifts: a big error by one side, and what the other side did with it.
    set gifts {}
    foreach m [_bySwing $bad 2] {
        set ply [dict get $m ply]
        set ans [::cr_review::moveByPly [expr {$ply + 1}]]
        set line "[::crfacts::phaseMoveLine $m]"
        if {$ans ne ""} {
            append line "; answered by [::crfacts::phaseMoveLine $ans]"
        } else {
            append line "; nobody could answer it, the game was over"
        }
        lappend gifts $line
    }
    if {[llength $gifts]} {
        lappend lines "chances offered and taken:"
        foreach g $gifts { lappend lines "  $g" }
    }

    # Each side's weakest phase, by that side's accuracy in it.
    set weak {}
    foreach side {white black} {
        set key accuracy_$side
        set worst "" ; set worstAcc 101.0
        foreach ph {opening middlegame endgame} {
            set st [dict get $R(phaseStats) $ph]
            if {$st eq ""} continue
            set a [dict get $st $key]
            if {$a < $worstAcc} { set worstAcc $a ; set worst $ph }
        }
        if {$worst ne ""} {
            lappend weak "[expr {$side eq "white" ? "White" : "Black"}]'s weakest phase: $worst"
        }
    }
    if {[llength $weak]} { lappend lines [join $weak {; }] }

    return [join $lines "\n"]
}

proc ::cr_llm::summaryPrompt {} {
    set facts [::cr_llm::summaryFacts]
    return "You are a chess coach writing the closing note of a game review, for the scoresheet.
Write about both sides by colour - \"White\" and \"Black\". Never address anyone as \"you\".

Rules:
- Use only the FACTS below. Never name a piece, square or move that is not in FACTS.
- Never quote accuracy, Elo, centipawn or percentage figures, and never list move tallies. The reader sees those beside the moves.
- Never call a move great, brilliant, best, an inaccuracy, a mistake or a blunder: the scoresheet already labels it. Say what the move did or allowed.
- Never name a better move without saying what it would have achieved: when FACTS says what the better move achieves, or gives the engine line, use it.
- Never invent an opening name, never quote an ECO code, and never remark that a name is missing: the header already carries the code.
- The game turned on the move in FACTS marked \"the game turned here\". Name it in your first sentence and do not say that any other move turned the game.
- Do not describe what a line or variation shows beyond the moves in it. If FACTS does not say what a move achieved, say less rather than guessing.
- Prefer the consequence over the sequence: Black taking on e4 and losing the queen to a rook is a summary; naming each move in order is not. If FACTS gives the net exchange, put it in the first sentence.
- FACTS says when the game was decided, with a move number. If you mention it, use that move number exactly. Mistakes made after that point did not change the result: mention them only as loose play in a lost position, never as being as important as the move that decided the game.
- No lists, no headings, no preamble, no markdown.
- Answer in exactly three labelled lines, each starting at the beginning of a line:
SUMMARY: at most three sentences, sixty words total, and preferably two. The FIRST sentence must name the move the game turned on AND its consequence in outcome terms - what it cost on the board, such as a queen for a rook or a lost piece - in that same sentence. Never spend a sentence on the mechanism; the reader has the scoresheet. Shape: the game turned on move 9, when Black's queen took the pawn on e4 and was won for a rook. Do not mention an error that did not change the result.
LEVEL: one sentence on the strength of play this game shows. Start from FACTS marked \"measured level\", naming each side's level in words; then name the single thing that would most have improved the weaker side's play in THIS game, stated concretely (for example, checking that a piece is defended before committing it). One game cannot show a habit or a pattern, so never use those words and never describe one. Do not retell the game and do not repeat the turning point.
OPENING: at most two sentences on the opening. If FACTS gives no opening name, write exactly NONE and say nothing else about it.
FACTS:
$facts"
}

# The model answers in labelled lines rather than JSON: Tcl has no JSON decoder
# here, and a small model gets three labelled lines right far more often than
# it gets escaped JSON right.
proc ::cr_llm::parseSummary {text fallback} {
    set out [dict create summary "" level "" opening ""]
    foreach line [split $text "\n"] {
        set t [string trim $line]
        foreach {tag key} {SUMMARY summary LEVEL level OPENING opening} {
            if {[string match -nocase "${tag}:*" $t]} {
                dict set out $key [string trim [string range $t [expr {[string length $tag] + 1}] end]]
            }
        }
    }
    if {[dict get $out summary] eq ""} {
        # no labels at all: the whole answer is the summary
        dict set out summary [string trim $text]
    }
    if {[string match -nocase {none*} [dict get $out opening]]} { dict set out opening "" }
    if {[dict get $out summary] eq ""} { dict set out summary $fallback }
    return $out
}

# ---- phase paragraphs ------------------------------------------------------
#
# Colour-neutral: this text goes into a scoresheet that a third party may read,
# so it says "White" and "Black", never "you". One paragraph per phase that
# actually has material (>= 4 plies).


# The moves worth naming in a phase: the player's and the opponent's notable
# ones, in game order, capped at 8. Empty means the phase was quiet - all book,
# all reasonable - and there is nothing for the coach to say beyond the numbers.
proc ::cr_llm::phaseNotable {phase} {
    upvar #0 ::cr_review::R R
    set st [dict get $R(phaseStats) $phase]
    if {$st eq ""} { return {} }
    set out {}
    set from [dict get $st from_ply]
    set to [dict get $st to_ply]
    # Only moves that changed the outcome of the phase. A move labelled
    # inaccuracy at +12 in a won game is noise: it cost almost no win chance.
    foreach m $R(movesOut) {
        set ply [dict get $m ply]
        if {$ply < $from || $ply > $to} continue
        if {[dict exists $m unsearched]} continue
        set sw [::cr_llm::_significance $m]
        set cls [dict get $m classification]
        if {$sw >= 1.0 || ($cls eq "brilliant" && $sw <= -1)} { lappend out $m }
        if {[llength $out] >= 8} break
    }
    return $out
}

proc ::cr_llm::phaseFacts {phase} {
    upvar #0 ::cr_review::R R
    set st [dict get $R(phaseStats) $phase]
    if {$st eq ""} { return "" }
    if {![info exists R(phaseMoves)]} { set R(phaseMoves) [dict create] }
    set lines {}
    lappend lines "phase: $phase"
    lappend lines "plies in this phase: [dict get $st plies]"
    lappend lines "accuracy: White [format %.1f [dict get $st accuracy_white]], Black [format %.1f [dict get $st accuracy_black]]"
    lappend lines "average centipawn loss: White [dict get $st acpl_white], Black [dict get $st acpl_black]"
    set firstM "" ; set lastM ""
    foreach m $R(movesOut) {
        set ply [dict get $m ply]
        if {$ply < [dict get $st from_ply] || $ply > [dict get $st to_ply]} continue
        if {$firstM eq ""} { set firstM $m }
        set lastM $m
    }
    if {$firstM ne ""} {
        set b0 [expr {[dict exists $firstM eval_before_cp] ? [dict get $firstM eval_before_cp] : 0}]
        set b1 [expr {[dict exists $lastM eval_after_cp] ? [dict get $lastM eval_after_cp] : 0}]
        lappend lines "state at the start of this phase: [balanceWord $b0]"
        lappend lines "state at the end of this phase: [balanceWord $b1]"
    }

    set notable {}
    foreach m [phaseNotable $phase] { lappend notable [::crfacts::phaseMoveLine $m] }
    if {[llength $notable]} {
        lappend lines "the moves that shaped this phase, in game order:"
        foreach n $notable { lappend lines "  $n" }
    } else {
        lappend lines "moves you may name in this phase: none"
    }
    return [join $lines "\n"]
}

proc ::cr_llm::phasePrompt {phase} {
    # Nothing noteworthy in the phase (a book opening, a quiet stretch) means
    # nothing worth a paragraph - and no call to pay for.
    if {![llength [phaseNotable $phase]]} { return "" }
    set facts [::cr_llm::phaseFacts $phase]
    if {$facts eq ""} { return "" }
    return "You are a chess coach writing one paragraph about the $phase of a game, for the scoresheet.
Write about both sides by colour - \"White\" and \"Black\". Never address anyone as \"you\".

Rules:
- Use only the FACTS below. Never name a piece, square or move that is not in FACTS.
- Name the concrete moves from FACTS that mattered and say what each one did or allowed. Do not stop at calling a move good or bad: the scoresheet already labels it.
- Open with one sentence on the state of this phase: who stood better when it began and whether that changed by its end.
- Then group by side: White's moves that mattered in game order, then Black's. Never alternate between the sides.
- Keep to the balance: if one side was already completely winning in this phase, say what the losing side was playing for rather than listing small errors.
- Never quote the accuracy, centipawn or ply figures from FACTS, and give no percentages. The reader sees those already.
- Never compare the two sides' accuracy, even in words: saying one side was more accurate is still a number in disguise.
- Never narrate the move sequence. The scoresheet already lists every move, so naming them one after another adds nothing.
- If FACTS says there are no moves you may name, write only about the phase as a whole and name no move at all.
- Keep both sides distinct: never credit one side with the other's move.
- No lists, no headings, no preamble. Two to four sentences of plain prose.
- End with one concrete thing the side that struggled should have done differently in this phase.
FACTS:
$facts"
}

# ---- drivers ---------------------------------------------------------------

# Prose for every key moment plus the game summary, then write it into the PGN.
proc ::cr_llm::startProse {} {
    variable J
    set J(jobs) {}
    set J(done) 0
    set J(texts) [dict create]
    set J(game) [sc_game number]
    set gnum $J(game)

    foreach k $::cr_review::R(keyMoments) {
        set m [::cr_review::moveByPly [dict get $k ply]]
        if {$m eq ""} continue
        # The reply that punished the move is in the next analysed position: its
        # PV starts from the board after the move, so it is the refutation. Attach
        # it here rather than in crfacts, which sees one record at a time.
        if {[catch {
            set nx [::cr_review::moveByPly [expr {[dict get $m ply] + 1}]]
            if {$nx ne "" && [dict exists $nx best_pv] && [llength [dict get $nx best_pv]]} {
                dict set m punish_pv [dict get $nx best_pv]
            }
        }]} {
            catch { ::cr_ui::log "prose: no punishment line for ply [dict get $m ply]" }
        }
        lappend J(jobs) [list moment [dict get $m ply] [::cr_llm::momentPrompt $m]]
    }
    if {$::cr_settings::s(phase_prose)} {
        foreach ph {opening middlegame endgame} {
            if {[catch { set pr [::cr_llm::phasePrompt $ph] }]} { continue }
            if {$pr ne ""} { lappend J(jobs) [list phase $ph $pr] }
        }
    }
    lappend J(jobs) [list summary 0 [::cr_llm::summaryPrompt]]
    set J(total) [llength $J(jobs)]
    ::cr_llm::nextJob
}

proc ::cr_llm::nextJob {} {
    variable J
    if {![llength $J(jobs)]} {
        ::cr_llm::applyProse
        return
    }
    set job [lindex $J(jobs) 0]
    set J(jobs) [lrange $J(jobs) 1 end]
    lassign $job kind ply prompt
    # The summary writes three fields in one answer and was being cut off at
    # 300 tokens mid-sentence; the phase paragraphs need a little more than a
    # single annotation.
    set budget [expr {$kind eq "summary" ? 800 : ($kind eq "phase" ? 500 : 320)}]
    ::cr_llm::ask $prompt [list ::cr_llm::onProse $kind $ply] $budget
}

proc ::cr_llm::onProse {kind ply text err} {
    variable J
    incr J(done)
    if {$err eq "" && $text ne ""} {
        dict set J(texts) [list $kind $ply] $text
    }
    catch { ::cr_ui::proseProgress $J(done) $J(total) }
    ::cr_llm::nextJob
}

proc ::cr_llm::applyProse {} {
    variable J
    if {![dict size $J(texts)]} return
    # the game may have changed while the model was thinking
    if {[catch { sc_game number }] || [sc_game number] != $J(game)} {
        catch { ::cr_ui::proseNote "Game changed while the coach was writing; prose discarded." }
        return
    }
    set ply0 [sc_pos location]
    undoFeature save
    if {[catch {
        foreach key [dict keys $J(texts)] {
            lassign $key kind ply
            if {$kind eq "phase"} {
                set ::cr_review::R(phase,$ply) [dict get $J(texts) $key]
                # A phase paragraph belongs at the end of its own phase: the
                # last ply it covers, which for the last phase is the last ply
                # of the game. There it reads as both a closing remark and the
                # heading for the phase that follows, and the reader stepping
                # through the game meets it where the events it describes are
                # on screen.
                set st ""
                catch { set st [dict get $::cr_review::R(phaseStats) $ply] }
                if {$st eq ""} continue
                set anchor [dict get $st to_ply]
                if {[catch { sc_move ply $anchor }]} continue
                if {[sc_pos location] != $anchor} continue
                set cur [sc_pos getComment]
                set block [::cr_llm::phaseBlock $ply $st [dict get $J(texts) $key]]
                catch { sc_pos setComment [string trim "$cur\n\n$block"] }
                continue
            }
            if {$kind eq "moment"} {
                if {[catch { sc_move ply $ply }]} continue
                if {[sc_pos location] != $ply} continue
                set cur [sc_pos getComment]
                catch { sc_pos setComment "[string trim $cur] - [::cr_llm::cleanProse [dict get $J(texts) $key]]" }
            }
        }
        sc_move ply 0
        set cur [sc_pos getComment]
        set sm [dict create summary "" level "" opening ""]
        if {[dict exists $J(texts) [list summary 0]]} {
            catch { set sm [::cr_llm::parseSummary [::cr_llm::cleanProse [dict get $J(texts) [list summary 0]]] ""] }
            set ::cr_review::R(summary) [dict get $sm summary]
            set ::cr_review::R(summaryLevel) [dict get $sm level]
            set ::cr_review::R(summaryOpening) [dict get $sm opening]
        }
        # The game review and the summary stay in the header: they are about the
        # whole game, which is what the top of the scoresheet is. The phase
        # paragraphs have gone to their own phases (above), so they are not
        # repeated here.
        set body [string trim $cur]
        if {[dict get $sm summary] ne ""} { append body "\n\n" [dict get $sm summary] }
        if {[dict get $sm opening] ne ""} { append body "\n\nOpening: " [dict get $sm opening] }
        if {[dict get $sm level] ne ""} { append body "\nLevel: " [dict get $sm level] }
        catch { sc_pos setComment [string trim $body] }
        sc_move ply $ply0
    } err]} {
        undoFeature undo
        catch { ::cr_ui::proseNote "Could not write prose: $err" }
        return
    }
    catch { sc_game save [sc_game number] }
    catch { ::notify::DatabaseModified [sc_base current] }
    catch { ::notify::PosChanged -pgn }
    catch { ::cr_ui::proseNote "Coach notes written into the PGN." }
}

# ---- threat probe ----------------------------------------------------------

# "What's the threat?" for the position on the board: the engine's best reply
# for the side to move *is* the opponent's threat, so no extra chess logic is
# needed - only one short search.
proc ::cr_llm::threatSafe {} {
    catch { ::cr_ui::log "threat: menu invoked" }
    if {[catch { ::cr_llm::threat } err]} {
        catch { ::cr_ui::log "threat FAILED: $err" }
        tk_messageBox -icon warning -title "scidCommunity" \
            -message "What's the threat? could not run:\n\n$err"
    }
}

proc ::cr_llm::threat {} {
    if {$::cr_settings::s(model) eq ""} {
        tk_messageBox -icon info -title "scidCommunity" -message \
            "Set an Ollama model first (Tools -> Game review -> Review settings)."
        return
    }
    set fen [sc_pos fen]
    catch { ::cr_ui::log "threat: fen=$fen engine=$::cr_settings::s(engine_analysis)" }
    set rc [::cr_engine::quick "position fen $fen" 14 [list ::cr_llm::threatReply $fen]]
    catch { ::cr_ui::log "threat: search launched ($rc)" }
    return $rc
}

proc ::cr_llm::sideName {fen} {
    return [expr {[lindex [split $fen] 1] eq "w" ? "White" : "Black"}]
}

# The threat IS the strongest move for whoever is on move, so describe that
# move in words and say what it achieves. Never echo engine coordinates: a
# reader who wanted "c7c6" can look at the board.
proc ::cr_llm::threatFacts {fen uci} {
    set d [::crfacts::describeMove $fen $uci]
    set mover [expr {[dict get $d side] eq "White" ? "w" : "b"}]
    set out [::crfacts::movePhrase $d]
    if {[dict get $d check]} { append out " with check" }
    if {[dict get $d mate]} { append out " and it is mate" }
    # Only the clauses that describe a threat: escaping or protecting belongs
    # in move annotations, not in an answer to "what is the threat?".
    set gains [::crfacts::gainsOf $fen $uci $mover]
    set threats {}
    foreach g $gains {
        if {[regexp {^(threatens|wins|attacks|threatens mate)} $g]} { lappend threats $g }
    }
    # A threat answer is about what the move does to the opponent, never about
    # the mover's own castling: those rights are stated in their own FACTS line.
    set filtered {}
    foreach g $threats { if {![string match {*castle*} $g]} { lappend filtered $g } }
    set threats $filtered
    if {![llength $threats]} {
        foreach g [lrange $gains 0 2] {
            if {[string match {*castle*} $g]} continue
            lappend threats $g
        }
    }
    if {[llength $threats]} {
        append out ", and it [join [lrange $threats 0 1] {, }]"
    }
    return $out
}

# What the engine's move actually does, in words, with the empty case stated
# rather than left blank: a blank line is an invitation to invent a purpose,
# which is how "it frees the bishop" appeared on a move that frees nothing.
proc ::cr_llm::threatAchieves {fen uci} {
    # The threat is what the side to move can do, so take the mover from the
    # position rather than from the move's own piece.
    set mover [expr {[lindex [split $fen] 1] eq "w" ? "w" : "b"}]
    set parts {}
    foreach g [::crfacts::gainsOf $fen $uci $mover] { lappend parts $g }
    set freed [::crfacts::freedPieces $fen $uci $mover]
    if {[llength $freed]} { lappend parts "it frees [join $freed { and }]" }
    if {![llength $parts]} {
        return "what it achieves: nothing immediate - no capture, no check, no new threat, and no piece of [::crfacts::sideWord $mover]'s is freed"
    }
    return "what it achieves: [join $parts {; }]"
}

proc ::cr_llm::threatReply {fen lines err} {
    if {$err ne ""} {
        tk_messageBox -icon warning -title "scidCommunity" -message "Engine unavailable: $err"
        return
    }
    set side [::cr_llm::sideName $fen]
    # A move the board will not accept is not describable: say so instead of
    # letting the facts be built from a position the engine did not mean.
    if {[llength $lines] && [catch { set lm [::crboard::legalMoves [::crboard::fromFen $fen]] }] == 0} {
        if {[llength $lm] && [lsearch -exact $lm [lindex $lines 0]] < 0} {
            catch { ::cr_ui::log "threat: engine returned [lindex $lines 0], not legal here" }
            tk_messageBox -icon warning -title "scidCommunity" -message \
                "The engine returned a move that is not legal in this position:\n\n[lindex $lines 0]\n\nNothing was reported."
            return
        }
    }
    if {![llength $lines]} {
        tk_messageBox -icon info -title "What's the threat?" \
            -message "$side has nothing forcing here: no move wins material or gives check."
        return
    }
    set repLine ""
    catch {
        set rc [::crfacts::repFromMainline $fen [sc_pos location]]
        if {$rc eq ""} {
            set repLine ""
        } else {
            set repLine [::crfacts::repetitionLine $rc]
        }
    }
    set ruleLines {}
    foreach l [list [::crfacts::castlingLine $fen] [::crfacts::epLine $fen] \
                     [::crfacts::clockLine $fen] $repLine] {
        if {$l ne ""} { lappend ruleLines $l }
    }
    set facts "[string tolower $side] is to move."
    foreach l $ruleLines { append facts "\n$l" }
    append facts "\nThe strongest move: [::cr_llm::threatFacts $fen [lindex $lines 0]]."
    append facts "\n[::cr_llm::threatAchieves $fen [lindex $lines 0]]"
    set fallback "$side's threat: [::cr_llm::threatFacts $fen [lindex $lines 0]]."
    set prompt "You are a chess coach telling a player what one side is threatening in the position on the board.
Write ONE sentence of at most 30 words: what $side is threatening, and why it matters to the opponent.

Rules:
- Use only the FACTS below. Do not invent pieces or squares.
- Never write a move in coordinates or algebraic notation. Describe the move in words.
- Never mention castling unless the FACTS line about castling says that side may still castle.
- Never say a move frees, develops, activates or opens a line for any piece unless FACTS names that piece. If FACTS says it achieves nothing immediate, say only that the move does something small and name nothing.
- Never mention en passant unless FACTS says a pawn can be captured that way, and never claim a position has repeated or that the fifty-move rule is close unless FACTS says so.
- Name $side explicitly. Never write the phrase \"the side to move\".
- No preamble, no lists.
FACTS:
$facts"
    ::cr_llm::ask $prompt [list ::cr_llm::threatShow $fallback] 220
}

proc ::cr_llm::plainText {text} {
    # Model output is UTF-8 read as the host codepage: typographic characters
    # arrive as mojibake and emoji as rubble. This dialog is short prose, so
    # anything outside printable ASCII is dropped rather than repaired.
    set t [::cr_llm::cleanProse $text]
    regsub -all {[^ -~\n\t]} $t {} t
    return [string trim [regsub -all {\s+} $t " "]]
}

proc ::cr_llm::threatShow {fallback text err} {
    set msg $fallback
    if {$err eq "" && [string trim $text] ne ""} {
        set clean [::cr_llm::plainText $text]
        if {$clean ne ""} { set msg $clean }
    }
    tk_messageBox -icon info -title "What's the threat?" -message $msg
}

# ---- model discovery --------------------------------------------------------
# Ask the endpoint what it has, so the model field is a pick instead of a guess.
# A wrong model name otherwise surfaces only as an empty reply at review time.
proc ::cr_llm::listModels {cb} {
    set base [string trimright $::cr_settings::s(api_url) /]
    ::cr_llm::fetchIds "$base/v1/models" [list ::cr_llm::listModelsStep $base $cb]
}

proc ::cr_llm::listModelsStep {base cb ids} {
    if {[llength $ids]} { catch { {*}$cb $ids "" } ; return }
    # Ollama's native endpoint, for a server without the OpenAI-compatible one
    ::cr_llm::fetchIds "$base/api/tags" [list ::cr_llm::listModelsDone $cb]
}

proc ::cr_llm::listModelsDone {cb ids} {
    if {![llength $ids]} {
        catch { {*}$cb {} "no model list from this endpoint" }
        return
    }
    catch { {*}$cb $ids "" }
}

proc ::cr_llm::fetchIds {url cb} {
    variable M
    set cmd [list | curl -s --max-time 10 -H {Accept: application/json}]
    if {$::cr_settings::s(api_key) ne ""} {
        lappend cmd -H "Authorization: Bearer $::cr_settings::s(api_key)"
    }
    lappend cmd $url
    if {[catch {
        set fd [open $cmd r]
        fconfigure $fd -blocking 0 -translation binary
    } err]} {
        catch { {*}$cb {} }
        return
    }
    set M(buf,$fd) ""
    set M(cb,$fd) $cb
    fileevent $fd readable [list ::cr_llm::onIds $fd]
}

proc ::cr_llm::onIds {fd} {
    variable M
    if {[catch { append M(buf,$fd) [read $fd] }]} {
        catch { close $fd }
        set cb $M(cb,$fd)
        unset -nocomplain M(buf,$fd) M(cb,$fd)
        catch { {*}$cb {} }
        return
    }
    if {![eof $fd]} { return }
    fileevent $fd readable ""
    catch { close $fd }
    set raw $M(buf,$fd)
    set cb $M(cb,$fd)
    unset -nocomplain M(buf,$fd) M(cb,$fd)
    set ids {}
    foreach {all id} [regexp -all -inline {"id"\s*:\s*"([^"]+)"} $raw] { lappend ids $id }
    if {![llength $ids]} {
        foreach {all nm} [regexp -all -inline {"name"\s*:\s*"([^"]+)"} $raw] { lappend ids $nm }
    }
    catch { {*}$cb $ids }
}
