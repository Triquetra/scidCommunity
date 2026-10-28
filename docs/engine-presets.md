# Engine presets

An entry in `engines.dat` describes one engine preset. Two presets may point at
the same binary and differ only in options, which is how "Stockfish Deep" and
"Stockfish Quick Review" coexist.

## What a preset holds

| Field | Meaning |
|---|---|
| `Name` | the key: windows, the review and the trainers find a preset by name |
| `Cmd`, `Args`, `Dir` | the binary and how to start it |
| `Elo`, `Time` | informational, used for sorting and display |
| `URL` | legacy slot, now holds `scoreside notation pvwrap debugframe priority netport` |
| `UCI`, `UCIoptions` | protocol flag and the UCI options the engine advertises (`Threads`, `Hash`, `MultiPV`, `SyzygyPath`, …) |
| `Limits` | search limits — see below |

## Search limits

`Limits` is a dict with three keys, any of which may be absent:

```
Limits {depth 66 movetime 300000 autorun 250}
```

- `depth` — search depth limit (1–500). Empty means unlimited.
- `movetime` — search time limit in milliseconds (1–3600000). Empty means unlimited.
- `autorun` — the default cadence used when the window autoruns the main line,
  in milliseconds. It is applied when an engine window opens and then lives in
  that window's Autorun control; changing the control does not write the preset
  back, so a preset's autorun is set in `engines.dat` (a preset editor will get
  a field for it).

Limits belong to the preset, not to the window and not to Scid globally, so the
same engine can be browsed at `movetime 100` under one preset and searched to
`depth 66` under another.

The engine window's depth and time entries read and write the limits of the
preset it is showing. Editing them saves `engines.dat` immediately; there is no
separate "Save Options" step for them. Only the keys a preset actually sets are
written, and saving depth or time leaves the preset's `autorun` alone.

### Files written by an older version

`Limits` is the tenth element of the entry. A preset that carries the field
writes it even when it is empty (`Limits {}`): that is how "all limits cleared"
survives a reload and overrides the legacy globals. An entry from a file written
before the field existed has nine elements and no `Limits` line, so it is
byte-identical to what an older version wrote; the legacy global options
(`enginewin::depth_limit` / `enginewin::movetime_limit`) still apply to it.
Those globals remain stored for this reason and are no longer edited by the UI.

## Where the code lives

- `tcl/tools/engine_limits.tcl` — the entry layout, validation, `Go` limit
  building and preset lookup (`::enginelimits::forName`).
- `tcl/tools/enginelist.tcl` — reads the file; accepts `Limits` as a dict, or a
  bare integer as the depth.
- `tcl/enginecfg.tcl` — writes the file, preserving element 9.
- `tcl/windows/engine.tcl` — `::enginewin::loadLimits` takes a window's limits
  from its preset; `applyLimits` stores them back.

## What the review does

A review pass runs on its own engine connection and sends `SetOptions` there.
It never writes to a preset: sharing a preset would otherwise change the values
the user browses with, and `::enginewin::changeOption` restarts the running
search when a value changes.
