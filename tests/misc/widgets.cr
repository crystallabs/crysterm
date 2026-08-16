# FEATURE: representative Qt-like widgets, 1 of 2 — basic controls.
#
# Six of Crysterm's 90+ widgets in a 3×2 grid of titled GroupBoxes:
#   * Button      — a push button; a script clicks it and a label counts
#   * CheckBox    — three boxes toggling on staggered beats
#   * LineEdit    — types a name (with placeholder text) and a password
#                   (EchoMode::Password masks it), then erases both
#   * List        — the selection walks down all items and back up
#   * ProgressBar — horizontal and vertical bars filling in step
#   * Slider      — a tick-marked slider sweeping its whole range
#
# Everything runs off one master clock: a 50-beat (5.0 s) cycle that divides
# the 5 s capture exactly and ends in the state it started in, so the looping
# animation wraps seamlessly whatever the recording's start phase.
#
# See widgets2.cr for part 2 (data views & composed inputs) and qt_widgets.cr
# for the full MainWindow chrome (menus, toolbars, docks, tabs …). No inline
# colors: everything is painted by the active theme (or pass
# `--colors-stylesheet data/css/<name>.qss` for a Qt theme).

require "../../src/crysterm"

include Crysterm

s = Window.new title: "Widgets 1/2"
s.border_junctions = true

Widget::Box.new parent: s, top: 0, left: 0, width: "100%", height: 1, parse_tags: true,
  content: "{center}{bold}Qt-like widgets 1/2{/bold} — Button · CheckBox · LineEdit · List · ProgressBar · Slider{/center}"

# The 3×2 grid: each widget sits in a titled 26×11 GroupBox cell.
cell = ->(row : Int32, col : Int32, title : String) do
  Widget::GroupBox.new parent: s,
    top: 1 + row * 11, left: 1 + col * 26, width: 26, height: 11, title: title
end

# --- Button ------------------------------------------------------------------

gb = cell.call 0, 0, "Button"
btn = Widget::Button.new parent: gb, top: 2, left: 2, width: 20, height: 3,
  content: "Submit", align: :center, focus_on_click: false,
  style: Style.new(border: true)
pressed = Widget::Box.new parent: gb, top: 6, left: 2, width: 20, height: 1, align: :center
clicks = 0
btn.on(Event::Pressed) do
  clicks += 1
  pressed.content = "pressed #{clicks}×"
end

# --- CheckBox ----------------------------------------------------------------

gb = cell.call 0, 1, "CheckBox"
cb1 = Widget::CheckBox.new parent: gb, top: 2, left: 2, width: 20, height: 1,
  content: "Autosave", checked: true
cb2 = Widget::CheckBox.new parent: gb, top: 4, left: 2, width: 20, height: 1,
  content: "Word wrap"
cb3 = Widget::CheckBox.new parent: gb, top: 6, left: 2, width: 20, height: 1,
  content: "Keep backups"

# --- LineEdit ----------------------------------------------------------------

gb = cell.call 0, 2, "LineEdit"
Widget::Box.new parent: gb, top: 2, left: 2, width: 6, height: 1, content: "Name:"
name = Widget::LineEdit.new parent: gb, top: 2, left: 8, width: 14, height: 1,
  placeholder_text: "type here…"
Widget::Box.new parent: gb, top: 4, left: 2, width: 6, height: 1, content: "Pass:"
pass = Widget::LineEdit.new parent: gb, top: 4, left: 8, width: 14, height: 1,
  echo_mode: :password

NAME   = "Ada Lovelace"
SECRET = "hunter42"

# --- List --------------------------------------------------------------------

gb = cell.call 1, 0, "List"
list = Widget::List.new parent: gb, top: 1, left: 1, right: 1, bottom: 1,
  items: ["main.cr", "window.cr", "widget.cr", "style.cr",
          "layout.cr", "event.cr", "tput.cr", "shard.yml"]

# --- ProgressBar -------------------------------------------------------------

gb = cell.call 1, 1, "ProgressBar"
Widget::Box.new parent: gb, top: 2, left: 2, width: 10, height: 1, content: "Download:"
pb_h = Widget::ProgressBar.new parent: gb, top: 3, left: 2, width: 16, height: 1
pb_v = Widget::ProgressBar.new parent: gb, top: 1, left: 20, width: 3, height: 7,
  orientation: :vertical

# --- Slider ------------------------------------------------------------------

gb = cell.call 1, 2, "Slider"
Widget::Box.new parent: gb, top: 2, left: 2, width: 8, height: 1, content: "Volume:"
slider = Widget::Slider.new parent: gb, top: 3, left: 2, width: 20, height: 2,
  minimum: 0, maximum: 100, value: 0, text_visible: true,
  tick_position: Widget::Slider::TickPosition::Below, tick_interval: 25

Widget::Box.new parent: s, top: 23, left: 0, width: "100%", height: 1, parse_tags: true,
  content: "{center}part 2: widgets2.cr · full chrome: qt_widgets.cr · q quits{/center}"

# --- Master clock ------------------------------------------------------------

# One 50-beat cycle (0.1 s per beat = 5.0 s) drives every cell; each widget's
# state is a pure function of `t = tick % 50`, so the scene is periodic and the
# capture loop is seamless: toggles come in pairs, sweeps are triangles or
# sawtooths, and t=0 resets the click counter and typed text.
tick = 0
s.every(0.1.seconds) do
  t = tick % 50
  tick += 1

  # Keep focus (and its highlight) deterministic across cycles.
  if t == 0
    list.focus
    clicks = 0
    pressed.content = ""
  end

  # Button: four scripted clicks per cycle.
  btn.click if t.in?(6, 16, 26, 36)

  # CheckBox: each box toggles twice per cycle, so it ends as it started.
  cb1.toggle if t.in?(5, 30)
  cb2.toggle if t.in?(10, 35)
  cb3.toggle if t.in?(15, 40)

  # LineEdit: type the name one char per beat, hold, then erase (the password
  # field follows along, masked to '*' by EchoMode::Password).
  n = case t
      when 8..19  then t - 7        # typing
      when 20..43 then NAME.size    # hold
      when 44..47 then (47 - t) * 3 # erase, three chars per beat
      else             0
      end
  v = NAME[0, n]
  name.value = v if name.value != v
  p = SECRET[0, Math.min(n, SECRET.size)]
  pass.value = p if pass.value != p

  # List: the selection walks to the last item, rests, and walks back.
  list.down if t.in?(5, 7, 9, 11, 13, 15, 17)
  list.up if t.in?(30, 32, 34, 36, 38, 40, 42)

  # ProgressBar: both orientations fill together, 0 → 98 %, then restart.
  pb_h.value = t * 2
  pb_v.value = t * 2

  # Slider: a triangle sweep over the full range and back.
  slider.value = t <= 25 ? t * 4 : (50 - t) * 4
end

# Focused from the very first frame — the clock only re-asserts it — so a
# recording that starts before the first beat still matches every later cycle.
# Pre-creating the scroll bar (Qt's `verticalScrollBar()`) matters for the same
# reason: left to its lazy mid-render creation it would miss the first frame's
# CSS cascade and flash unthemed for exactly one frame.
list.focus
list.vertical_scrollbar

s.exec
