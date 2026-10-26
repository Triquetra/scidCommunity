
# getClipboardText:
#   Returns the text currently on the system clipboard, with surrounding
#   whitespace removed. If the CLIPBOARD selection is unavailable, the
#   PRIMARY selection (the X11 middle-click buffer) is tried. Returns the
#   empty string if no text could be read. If varName is given, the text is
#   also stored in that variable, but only when text was found, so callers
#   can keep an existing value when the clipboard is empty.
#
#   Tk's "selection get" asks the clipboard owner for the STRING target by
#   default, and its man page warns that it never asks for UTF8_STRING
#   unless told to. On Wayland desktops the clipboard is usually owned by
#   the compositor or a clipboard manager through XWayland, and those
#   owners commonly offer UTF8_STRING only and refuse STRING, so a plain
#   "selection get -selection CLIPBOARD" fails there. Asking for both
#   targets keeps paste working on those systems. Windows and macOS have a
#   single native clipboard that answers any target, so STRING is always
#   tried first and the extra attempt changes nothing there.
#
proc ::utils::getClipboardText {{varName ""}} {
  foreach selection {CLIPBOARD PRIMARY} {
    foreach type {STRING UTF8_STRING} {
      if {![catch {selection get -selection $selection -type $type} text]
            && $text ne ""} {
        set text [string trim $text]
        if {$varName ne ""} {
          upvar 1 $varName var
          set var $text
        }
        return $text
      }
    }
  }
  return ""
}

# thousands, percentFormat:
#   Functions to format integer numbers.
#   thousands inserts the thousands separator (usually "," or ".") for
#   every three digits before the decimal separator in the number.
#   percentFormat does the same as thousands, but also adds a percentage.
#   If "kilo" is true, numbers >= 100,000 are divided by 1000 and have
#   the unit "K" appended while values over 1 million appear as "1.00M"
#
proc ::utils::thousands {n {kilo 0}} {
  global locale
  set commaChar [string index $locale(numeric) 1]
  set unit ""
  if {$kilo} {
    if {$n >= 1000000} {
      set decimalChar [string index $locale(numeric) 0]
      set decimalPart [format "%02d" [expr {(int($n / 10000)) % 100}]]
      set n [expr {int($n) / 1000000}]
      set unit "${decimalChar}${decimalPart}M"
    } elseif {$n >= 100000} {
      set unit "K"
      set n [expr {int($n / 1000)} ]
    }
  }
  if {$commaChar == ""} { return "$n$unit" }
  while {[regsub {^([-+]?[0-9]+)([0-9][0-9][0-9])} $n "\\1$commaChar\\2" n]} {}
  return "$n$unit"
}

proc ::utils::percentFormat {num denom} {
  # Ensure denominator is not zero:
  if {$denom == 0} {set denom 1}
  return "[::utils::thousands $num] ([expr $num * 100 / $denom]%)"
}

