#!/usr/bin/env tclsh
# Copyright (C) 2026 David Crandall
# SPDX-License-Identifier: GPL-2.0-or-later
#
# annotate_i18n.tcl -- the Annotate dialog's note is translated, not left as the
# English placeholder.
#
#   tclsh tests/tcl/annotate_i18n.tcl
#
# ::configAnnotation shows a note whose text comes from the tag
# AnnotateVariationsMainLineOnly (tcl/tools/analysis.tcl). The string was added to
# english.tcl and copied verbatim into every other language file, so a user
# running Scid in one of those languages read English in the middle of a
# translated dialog. A language file that does not define the tag at all is a
# different bug - the dialog would show the tag name - so both are checked here.
#
# The language files are read as text: they are data (translate / menuText /
# helpMsg lines) and sourcing one needs the whole application. Every file that
# carries translate entries is checked; the helper scripts in tcl/lang
# (checklangs, propagatelang, removedeadlang, removetoken) carry none and are
# skipped.
#
# `translated` lists the languages whose entry is done. serbian.tcl is not in it:
# it is deliberately outside the machine-translation pipeline
# (tcl/lang/propagatelang.tcl) and its file is mostly English by design. Adding a
# language is a line in that list - the harness reads the file, it does not hold a
# copy of the string.

set fails 0
set checks 0

proc check {label cond {detail ""}} {
    incr ::checks
    if {$cond} {
        puts "  ok   $label"
    } else {
        incr ::fails
        if {$detail eq ""} {
            puts "  FAIL $label"
        } else {
            puts "  FAIL $label -- $detail"
        }
    }
}

proc checkEq {label got want} {
    check $label [expr {$got eq $want}] "got '$got' want '$want'"
}

set root [file normalize [file join [file dirname [info script]] .. ..]]
set langDir [file join $root tcl lang]

proc readLang {path} {
    set fh [open $path r]
    fconfigure $fh -encoding utf-8
    set text [read $fh]
    close $fh
    return $text
}

# The code and the text a language file gives a tag, {} when it does not define
# it: "translate L Tag {text}". This tag is a single-line entry.
proc langEntry {text tag} {
    foreach line [split $text "\n"] {
        if {[regexp "^translate\\s+(\\S+)\\s+$tag\\s+\\{(.*)\\}\\s*\$" \
                [string trim $line] -> code value]} {
            return [list $code $value]
        }
    }
    return {}
}

# The code letter a file's entries use, so an entry copied from english.tcl with
# the "E" left in place is caught rather than passing as a translation.
proc langCode {text} {
    foreach line [split $text "\n"] {
        if {[regexp "^translate\\s+(\\S+)\\s" [string trim $line] -> code]} {
            return $code
        }
    }
    return ""
}

# A translation is a string of its own: the English text is what the placeholder
# holds, and an empty value would show the tag name.
proc isTranslated {value english} {
    return [expr {$value ne "" && $value ne $english}]
}

set tag AnnotateVariationsMainLineOnly
set translated {romanian russian spanish swahili swedish turkish ukrainian}

########################################################################
### The check itself

puts "\nthe translation check distinguishes a translation from the placeholder"

set english [readLang [file join $langDir english.tcl]]
set englishEntry [langEntry $english $tag]
check "english.tcl defines $tag" [expr {[llength $englishEntry] == 2}]
set englishText [lindex $englishEntry 1]
check "the English entry has text" [expr {$englishText ne ""}] "got '$englishText'"

# The check has teeth: the placeholder is not a translation, and neither is an
# empty value.
check "the English text is not a translation" \
    [expr {![isTranslated $englishText $englishText]}]
check "an empty value is not a translation" [expr {![isTranslated "" $englishText]}]
check "a different string is a translation" \
    [expr {[isTranslated "$englishText (ro)" $englishText]}]

########################################################################
### Every language file, and the ones that are translated

puts "\nevery language file defines the tag, and the translated ones translate it"

set seen {}
set todo {}
set files [lsort [glob -nocomplain [file join $langDir *.tcl]]]
foreach path $files {
    set text [readLang $path]
    set code [langCode $text]
    # A helper script, not a language file.
    if {$code eq ""} { continue }
    set name [file rootname [file tail $path]]
    lappend seen $name

    set entry [langEntry $text $tag]
    if {[llength $entry] != 2} {
        check "$name defines $tag" 0 "the file has no entry for the tag"
        continue
    }
    checkEq "$name uses its own code for $tag" [lindex $entry 0] $code

    set value [lindex $entry 1]
    if {[lsearch -exact $translated $name] >= 0} {
        check "$name translates $tag" [isTranslated $value $englishText] \
            "still the English placeholder"
    } elseif {$name ne "english" && $value eq $englishText} {
        lappend todo $name
    }
}

# A glob that found nothing would pass every check above.
check "the language files were read" [expr {[llength $seen] >= 29}] \
    "read [llength $seen]"
foreach name $translated {
    check "$name is one of the files read" \
        [expr {[lsearch -exact $seen $name] >= 0}]
}

# The dialog has to be asking for this tag, or the translation is dead text.
set analysis [readLang [file join $root tcl tools analysis.tcl]]
check "the dialog asks for $tag" \
    [expr {[string first $tag $analysis] >= 0}]

if {[llength $todo]} {
    puts "\nstill the English placeholder (translator work, not a failure here):\
        [join $todo { }]"
}

puts "\n$checks checks, $fails failures"
exit [expr {$fails ? 1 : 0}]
