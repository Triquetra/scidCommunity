# Presentation Board window

A board-only window that follows the main board, for showing a game to an
audience (projector, second monitor, screen share) while the notation, engine
and database windows stay on the presenter's screen. Requested in
[discussion #348](https://github.com/whelanh/scidCommunity/discussions/348).

## Opening and closing

- **Windows → Presentation Board**, or **Ctrl+Shift+W** from the main window.
- Close it with the same key, the menu entry, or the window's close button.

## What it shows

- The current position, including positions inside variations.
- Arrows and square marks stored in the position's comment.
- The last-move indicator (highlight squares and/or arrow, according to
  **Options → Moves**), including NAG/eval badges if enabled.
- Flipping the main board (toolbar button, `.` key, menu, or a game loaded
  with the FlipB flag) also flips the presentation board. The window opens in
  the main board's current orientation.

The board is read-only: there are no move-entry bindings in this window.

## Controls

From the main window:

| Key | Action |
|---|---|
| `Ctrl+Shift+W` | Open/close the presentation window |
| `Ctrl+Shift+F` | Freeze/resume following the main board |

With the presentation window focused (click the board first):

| Key | Action |
|---|---|
| `f` | Flip the presentation board alone, leaving the main board unchanged |
| `F11` | Toggle fullscreen |
| `Esc` | Leave fullscreen |
| `Ctrl+Shift+F` | Freeze/resume following the main board |
| `Ctrl+Shift+W` | Close the window |

Flipping the main board after a local `f` flip brings the two boards back to
the same orientation.

## Freezing

While frozen, the presentation board keeps the position it is showing. The
rest of scidCommunity remains usable: load games, navigate, enter variations
and examine the solution without revealing it to the audience. Press
`Ctrl+Shift+F` again (or click the message on the main board) to resume.

The freeze state is shown only in the presenter's window — on the main board's
info bar and as a checkmark next to **Windows → Freeze Presentation Board** —
never on the presentation board itself.

## Showing it to an audience

A projector or second monitor displays a *screen*, not a single window, so the
display must be set to **extended** rather than mirrored. Move the window to
that screen, click the board to give it keyboard focus, then press `F11`.
Only this window is then projected.

- **Mirrored displays** show the same content on both screens, so nothing can
  be hidden from the audience.
- **Tiling compositors** (for example Hyprland) place windows themselves.
  There the window opens where the compositor puts it; a compositor window rule
  matching the title `scidCommunity: Presentation Board` can keep it on the
  presentation output. The app's remembered geometry applies only on window
  managers that let windows choose their own position.
- **Window size** does not change the board's resolution: the board uses the
  largest of its built-in sizes that fits the window, so fullscreen gives the
  largest board.
