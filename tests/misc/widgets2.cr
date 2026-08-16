# FEATURE: representative Qt-like widgets, 2 of 2 — data views & composed inputs.
#
# Six more of Crysterm's 90+ widgets in a 3×2 grid of titled GroupBoxes:
#   * ComboBox  — the script opens the drop-down, walks its rows and commits
#   * SpinBox   — an integer spinner (with suffix) plus a DoubleSpinBox
#   * Dial      — a rotary dial doing full turns, mirrored by an LCDNumber
#   * Table     — fixed-grid table whose numeric cells update live
#   * Tree      — a node hierarchy expanding and collapsing branches
#   * Calendar  — a month view: the selected day steps through while the
#                 month and year drop-downs each pop open for a moment
#
# Everything runs off one master clock: a 50-beat (5.0 s) cycle that divides
# the 5 s capture exactly and ends in the state it started in, so the looping
# animation wraps seamlessly whatever the recording's start phase.
#
# See widgets.cr for part 1 (basic controls) and qt_widgets.cr for the full
# MainWindow chrome (menus, toolbars, docks, tabs …). No inline colors:
# everything is painted by the active theme (or pass
# `--colors-stylesheet data/css/<name>.qss` for a Qt theme).

require "../../src/crysterm"

include Crysterm

s = Window.new title: "Widgets 2/2"
s.border_junctions = true

Widget::Box.new parent: s, top: 0, left: 0, width: "100%", height: 1, parse_tags: true,
  content: "{center}{bold}Qt-like widgets 2/2{/bold} — ComboBox · SpinBox · Dial · Table · Tree · Calendar{/center}"

# The 3×2 grid: each widget sits in a titled 26×11 GroupBox cell.
cell = ->(row : Int32, col : Int32, title : String) do
  Widget::GroupBox.new parent: s,
    top: 1 + row * 11, left: 1 + col * 26, width: 26, height: 11, title: title
end

# --- ComboBox ----------------------------------------------------------------

gb = cell.call 0, 0, "ComboBox"
Widget::Box.new parent: gb, top: 2, left: 2, width: 7, height: 1, content: "Theme:"
combo = Widget::ComboBox.new parent: gb, top: 2, left: 9, width: 13, height: 1,
  options: ["Breeze", "Nord", "Solarized", "Tokyo Night", "Gruvbox"]
Widget::Box.new parent: gb, top: 5, left: 2, width: 20, height: 2,
  content: "The drop-down opens\nover the cell below."

# --- SpinBox -----------------------------------------------------------------

gb = cell.call 0, 1, "SpinBox"
Widget::Box.new parent: gb, top: 2, left: 2, width: 7, height: 1, content: "Qty:"
spin = Widget::SpinBox.new parent: gb, top: 2, left: 9, width: 13, height: 1,
  minimum: 0, maximum: 25, value: 0, suffix: " pcs"
Widget::Box.new parent: gb, top: 4, left: 2, width: 7, height: 1, content: "Ratio:"
dspin = Widget::DoubleSpinBox.new parent: gb, top: 4, left: 9, width: 13, height: 1,
  minimum: 0.0, maximum: 1.0, single_step: 0.04, value: 0.0

# --- Dial (with an LCDNumber readout) ----------------------------------------

gb = cell.call 0, 2, "Dial"
# `wrapping` maps the range onto the full circle, so 360° lands back on the
# 0° pointer and the revolution below is seamless.
dial = Widget::Dial.new parent: gb, top: 2, left: 2, width: 9, height: 4,
  minimum: 0, maximum: 360, value: 0, wrapping: true
lcd = Widget::LCDNumber.new parent: gb, top: 2, left: 12, width: 11, height: 3,
  digit_count: 3
lcd.display 0
Widget::Box.new parent: gb, top: 6, left: 12, width: 11, height: 1, content: "degrees"

# --- Table -------------------------------------------------------------------

gb = cell.call 1, 0, "Table"
# CPU/MB readings per host, cycled below. Constant digit counts keep the
# content-sized columns from re-measuring between beats.
CPU = {
  "web"   => [42, 45, 51, 60, 72, 81, 74, 63, 55, 47],
  "db"    => [67, 65, 62, 58, 55, 57, 61, 66, 70, 69],
  "cache" => [12, 14, 18, 25, 33, 38, 34, 27, 20, 15],
}
MB = {
  "web"   => [512, 518, 530, 549, 575, 590, 578, 556, 534, 519],
  "db"    => [896, 891, 884, 877, 872, 874, 880, 888, 894, 897],
  "cache" => [128, 131, 137, 148, 161, 169, 163, 152, 141, 132],
}
table_rows = ->(i : Int32) do
  [["Host", "CPU%", "MB"]] +
  CPU.keys.map { |h| [h, CPU[h][i].to_s, MB[h][i].to_s] }
end
table = Widget::Table.new parent: gb, top: 2, left: 2, rows: table_rows.call(0)

# --- Tree --------------------------------------------------------------------

gb = cell.call 1, 1, "Tree"
tree = Widget::Tree.new parent: gb, top: 1, left: 1, right: 1, bottom: 1
src = tree.add "src"
wdir = src.add "widget"
wdir.add "tree.cr"
src.add "layout"
docs = tree.add "docs"
docs.add "README.md"
tree.add "shard.yml"
tree.expand src

# --- Calendar ----------------------------------------------------------------

gb = cell.call 1, 2, "Calendar"
# A pinned month (rather than "now") keeps the capture reproducible.
cal = Widget::Calendar.new parent: gb, top: 1, left: 1, width: 22, height: 8,
  date: Time.utc(2026, 6, 1)

Widget::Box.new parent: s, top: 23, left: 0, width: "100%", height: 1, parse_tags: true,
  content: "{center}part 1: widgets.cr · full chrome: qt_widgets.cr · q quits{/center}"

# --- Master clock ------------------------------------------------------------

# One 50-beat cycle (0.1 s per beat = 5.0 s) drives every cell; each widget's
# state is a pure function of `t = tick % 50`, so the scene is periodic and the
# capture loop is seamless: the combo commits "Tokyo Night" and then commits
# "Breeze" back, the tree closes every branch it opened, the calendar dismisses
# both of its nav drop-downs unchanged, and the sweeps are triangles or
# sawtooths.
popup = -> { combo.popup_widget.as?(Widget::ComboBox::Popup) }
tick = 0
s.every(0.1.seconds) do
  t = tick % 50
  tick += 1

  # Keep focus (and its highlight) deterministic across cycles.
  combo.focus if t == 0

  # ComboBox: open the drop-down, walk down to "Tokyo Night", commit; then
  # reopen and walk back up to "Breeze" so the cycle ends where it began.
  case t
  when 5, 27      then combo.show_popup
  when 8, 11, 14  then popup.call.try &.down
  when 30, 33, 36 then popup.call.try &.up
  when 17, 39     then popup.call.try &.activate_current
  end

  # SpinBox: integer triangle sweep; DoubleSpinBox: 0.00 → 0.96 sawtooth.
  spin.value = t <= 25 ? t : 50 - t
  dspin.value = t * 0.02

  # Dial: one full revolution per cycle (360° ≡ 0° at the wrap), LCD mirroring.
  dial.value = t * 36 // 5
  lcd.display dial.value

  # Table: fresh CPU/MB readings every fifth beat, ten states per cycle.
  table.rows = table_rows.call(t // 5) if t % 5 == 0

  # Tree: open and close the "widget" and "docs" branches, twice each so the
  # cycle ends fully back in the starting shape.
  case t
  when  8 then tree.expand wdir
  when 18 then tree.collapse wdir
  when 28 then tree.expand docs
  when 38 then tree.collapse docs
  end

  # Calendar: the selected day advances every other beat, 1st → 25th, and each
  # nav drop-down pops open for a moment — the highlight walks a couple of rows,
  # then dismisses unchanged, so the page (and the cycle) end where they began.
  # Both sessions sit in beats where the combo's popup is closed, so its focus
  # is only borrowed while nothing else is animating a popup.
  cal.selected_date = Time.utc(2026, 6, 1 + (t // 2))
  case t
  when 18 then cal.show_month_menu
  when 20 then cal.month_menu.try &.hover_item 6 # highlight July …
  when 22 then cal.month_menu.try &.hover_item 7 # … then August
  when 24 then cal.month_menu.try &.hide_popup
  when 40 then cal.show_year_menu
  when 42 then cal.year_menu.try &.hover_item 101 # highlight 2027 …
  when 44 then cal.year_menu.try &.hover_item 103 # … then 2029
  when 46 then cal.year_menu.try &.hide_popup
  end
end

# Focused from the very first frame — the clock only re-asserts it — so a
# recording that starts before the first beat still matches every later cycle.
combo.focus

s.exec
