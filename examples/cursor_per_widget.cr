require "../src/crysterm"

# Per-widget cursor demo — 6 boxes.
#
# Each focusable box carries its OWN terminal cursor. The left column uses
# ARTIFICIAL cursors (drawn by Crysterm into the buffer); the right column uses
# the terminal's HARDWARE cursor (real DECSCUSR shape, positioned by escape).
#
#   Left  (artificial):  line (cyan) · custom ▮ (magenta) · underline (green)
#   Right (hardware):     block · underline · bar/line (red)
#
# The cursor's *appearance* is resolved per-widget by `Screen#active_cursor`
# (the focused widget's cursor, or the screen default). This demo only manages
# the cursor's *position* and which kind (artificial vs hardware/real) is shown.
#
# Tab / Shift-Tab move focus (library `tab_navigation`); q or Ctrl-Q quits.
#
# Notes:
# * `Cursor#_hidden` defaults to true, so every cursor is made visible below.
# * Position is set from the `Focus` event — Crysterm re-emits it on the focused
#   widget every frame, AFTER draw. That ordering is exactly right: a HARDWARE
#   cursor must be positioned after the frame's drawing, and an ARTIFICIAL cursor
#   only needs its position one frame early (it converges, see below).
# * We re-render (and toggle the real cursor on/off) ONLY when the target
#   position changes — i.e. on a focus switch. Rendering unconditionally from a
#   Focus handler would loop forever (render -> Focus -> render -> ...).
# * A hardware shape the terminal can't style (underline/bar on a terminal
#   without DECSCUSR) is transparently drawn as an artificial cursor instead —
#   so the demo still shows something everywhere.

class PerWidgetCursorDemo
  include Crysterm
  include Tput::Namespace

  s = Screen.new title: "Per-widget cursor demo (6 boxes)"

  make_box = ->(top : String, left : Int32, text : String) do
    Widget::Box.new \
      parent: s,
      top: top,
      left: left,
      width: 38,
      height: 5,
      content: text,
      keys: true, # focusable / part of the Tab order
      style: Style.new(fg: "white", bg: "blue", border: true)
  end

  # Left column — artificial cursors.
  box1 = make_box.call "3%", 3, "Box 1 — ARTIFICIAL line (cyan)\n\n[Tab]/[Shift-Tab] move   [q] quit"
  box2 = make_box.call "37%", 3, "Box 2 — ARTIFICIAL custom ▮ (magenta)"
  box3 = make_box.call "70%", 3, "Box 3 — ARTIFICIAL underline (green)"

  # Right column — hardware (real terminal) cursors.
  box4 = make_box.call "3%", 43, "Box 4 — HARDWARE block"
  box5 = make_box.call "37%", 43, "Box 5 — HARDWARE underline"
  box6 = make_box.call "70%", 43, "Box 6 — HARDWARE bar/line (red)"

  # --- Artificial cursors: set shape/colors and make them visible. ---
  c1 = box1.cursor!
  c1.artificial = true
  c1.shape = :line
  c1.style.fg = "cyan"
  c1._hidden = false

  c2 = box2.cursor!
  c2.artificial = true
  c2.shape = :none
  c2.style.char = '▮'
  c2.style.fg = "magenta"
  c2.style.bg = "yellow"
  c2._hidden = false

  c3 = box3.cursor!
  c3.artificial = true
  c3.shape = :underline
  c3.style.fg = "green"
  c3._hidden = false

  # --- Hardware cursors: leave `artificial` false; the terminal renders them.
  # `_hidden` is set false too, so that if the terminal can't style a shape and
  # Crysterm falls back to an artificial cursor, it still shows. ---
  c4 = box4.cursor!
  c4.shape = :block
  c4._hidden = false

  c5 = box5.cursor!
  c5.shape = :underline
  c5._hidden = false

  c6 = box6.cursor!
  c6.shape = :line
  c6.style.fg = "red" # hardware cursor color (OSC 12) where supported
  c6._hidden = false

  # Position the cursor inside the focused box, and show the right KIND of cursor:
  # for an (effectively) artificial cursor hide the real terminal cursor (only the
  # drawn one should show); for a hardware cursor show the real one. Done only on
  # a focus switch (when the target position changes) so rendering converges and
  # never loops.
  applied = {-1, -1}
  place_cursor = ->(w : Widget) do
    w.lpos.try do |pos|
      target = {pos.yi + 2, pos.xi + 2}
      if target != applied
        applied = target
        s.tput.cursor_pos target[0], target[1]
        # `active_cursor.artificial?` reflects any hardware->artificial fallback
        # decided during focus (`apply_cursor`), so this stays correct.
        if s.active_cursor.artificial?
          s.tput.hide_cursor # only the drawn cursor should be visible
        else
          s.tput.show_cursor # real terminal cursor
        end
        s.render
      end
    end
  end

  {box1, box2, box3, box4, box5, box6}.each do |b|
    b.on(Event::Focus) { place_cursor.call b }
  end

  s.on(Event::KeyPress) do |e|
    if e.char == 'q' || e.key == Tput::Key::CtrlQ
      s.destroy
      exit
    end
  end

  # Focus the first box and kick off the first frame; `place_cursor` settles the
  # cursor into the box once layout (`lpos`) is known.
  box1.focus
  s.render

  s.exec
end
