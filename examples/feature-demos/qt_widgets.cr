# FEATURE: Qt-inspired widgets.
#
# Showcases the Qt-modeled widgets working together:
#   * TabWidget        — closable pages "Controls" / "Menu" / "Tree" / "Dates" / "Stack"
#   * GroupBox         — checkable title disables/enables its contents
#   * Tree             — collapsible node hierarchy (Right/Left expand/collapse)
#   * ComboBox         — editable: type to filter the options
#   * Slider (w/ ticks) / SpinBox / Dial — value controls that emit events
#   * DateEdit / TimeEdit / DoubleSpinBox — date/time and float entry
#   * Menu             — with nested submenus (File ▶ Recent ▶ …)
#   * StackedWidget    — auto-cycling pages (no tab bar)
#   * Splitter         — three panes with draggable dividers
#
# Layout: an HBox (Layout::HBox) fills the area between the header and status
# bar, splitting it between the tabbed area and the splitter and stretching both
# to full height — so the demo re-flows to the terminal size instead of relying
# on fixed coordinates. The status bar updates live from widget events.
#
# Try it: resize the terminal and watch the two regions re-flow; Tab cycles
# focus; arrows adjust the focused Slider/SpinBox/Dial; type in the ComboBox to
# filter; in the Menu, Right opens a submenu and Left closes it; drag a splitter
# divider (or focus it and use the arrows). Press q to quit.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "Qt-like Widgets"

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Qt-inspired widgets — click a control to focus it · arrows adjust · type filters the combo · q quits{/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#303050")

status = Widget::Box.new \
  parent: s, bottom: 0, left: 0, width: "100%", height: 1,
  style: Style.new(fg: "black", bg: "cyan")

# Everything between the header and the status bar lives in a single responsive
# row: an HBox layout splits the width between the tabbed area and the splitter,
# and stretches both to the full available height. Resize the terminal and the
# two regions re-flow to fit — no fixed coordinates to overflow a small screen.
body = Widget::Box.new \
  parent: s, top: 1, left: 0, right: 0, bottom: 1,
  layout: Layout::HBox.new(gap: 1)

# --- Tabbed area (left) ------------------------------------------------------

# No explicit position/size: the HBox sizes and places it (it grows to share the
# row, and stretches to full height).
tabs = Widget::TabWidget.new \
  parent: body,
  tabs_closable: true, # each tab shows ✕; Delete (on the bar) closes the current one
  style: Style.new(border: true)

controls = Widget::Box.new
menupage = Widget::Box.new
treepage = Widget::Box.new
datespage = Widget::Box.new
stackpage = Widget::Box.new
tabs.add_tab "Controls", controls
tabs.add_tab "Menu", menupage
tabs.add_tab "Tree", treepage
tabs.add_tab "Dates", datespage
tabs.add_tab "Stack", stackpage

# Controls tab: a checkable GroupBox holding the value widgets.
gb = Widget::GroupBox.new \
  parent: controls, top: 1, left: 1, right: 1, bottom: 1,
  title: "Profile", checkable: true, checked: true,
  style: Style.new(fg: "white", border: true)

Widget::Box.new parent: gb, top: 1, left: 1, width: 8, height: 1, content: "Volume:"
slider = Widget::Slider.new \
  parent: gb, top: 1, left: 9, width: 16, height: 2,
  minimum: 0, maximum: 100, value: 40, show_value: true,
  tick_position: Widget::Slider::TickPosition::Below, tick_interval: 20,
  style: Style.new(fg: "green")

Widget::Box.new parent: gb, top: 3, left: 1, width: 8, height: 1, content: "Count:"
spin = Widget::SpinBox.new \
  parent: gb, top: 3, left: 9, width: 12, height: 1,
  minimum: 0, maximum: 10, value: 3, suffix: " items",
  style: Style.new(fg: "yellow")

Widget::Box.new parent: gb, top: 5, left: 1, width: 8, height: 1, content: "Angle:"
dial = Widget::Dial.new \
  parent: gb, top: 5, left: 9, width: 7, height: 3,
  minimum: 0, maximum: 360, value: 90,
  style: Style.new(fg: "magenta")

# Color combo placed last so its drop-down opens *below* the other controls
# (into free space) instead of covering them.
Widget::Box.new parent: gb, top: 9, left: 1, width: 8, height: 1, content: "Color:"
combo = Widget::ComboBox.new \
  parent: gb, top: 9, left: 9, width: 16, height: 1, editable: true,
  options: ["Red", "Green", "Blue", "Cyan", "Magenta", "Maroon"],
  style: Style.new(fg: "white", bg: "#303030")

# Menu tab: a menu with nested submenus.
menu = Widget::Menu.new parent: menupage, top: 1, left: 1, width: 22, height: 10,
  style: Style.new(fg: "white", border: true)

mk = ->(text : String, msg : String) do
  a = Action.new text
  a.on(Event::Triggered) { status.set_content " menu: #{msg}"; s.render }
  a
end

recent = Action.new "Recent"
recent.submenu = [mk.call("report.txt", "open report.txt"), mk.call("notes.md", "open notes.md")]
file = Action.new "File"
file.submenu = [mk.call("New", "new file"), mk.call("Open", "open file"), recent]

wrap = Action.new "Word Wrap"
wrap.checkable = true

menu << file
menu.add_separator
menu << wrap
menu << mk.call("About", "about")

Widget::Box.new parent: menupage, bottom: 1, left: 1, width: 34, height: 2,
  content: "Right opens a submenu, Left closes it.", style: Style.new(fg: "#aaaaaa")

# Tree tab: a collapsible node hierarchy.
tree = Widget::Tree.new parent: treepage, top: 1, left: 1, right: 1, bottom: 3,
  style: Style.new(fg: "white", border: true)
src = tree.add "src"
wdir = src.add "widget"
wdir.add "tree.cr"
wdir.add "slider.cr"
src.add "layout"
docs = tree.add "docs"
docs.add "README.md"
tree.add "shard.yml"
tree.expand src # show "src" expanded to start

tree.on(Event::SelectItem) { status.set_content " tree: #{tree.selected_node.try(&.text)}"; s.render }
tree.on(Event::Expand) { status.set_content " tree: expanded #{tree.selected_node.try(&.text)}"; s.render }
tree.on(Event::Collapse) { status.set_content " tree: collapsed #{tree.selected_node.try(&.text)}"; s.render }

Widget::Box.new parent: treepage, bottom: 1, left: 1, width: 34, height: 2,
  content: "Right/Left or Space expand/collapse nodes.", style: Style.new(fg: "#aaaaaa")

# Dates tab: a DateEdit (with calendar popup), a TimeEdit, and a DoubleSpinBox.
Widget::Box.new parent: datespage, top: 1, left: 1, width: 8, height: 1, content: "Date:"
dateedit = Widget::DateEdit.new \
  parent: datespage, top: 1, left: 9, width: 12, height: 1,
  style: Style.new(fg: "white", bg: "#303030")

Widget::Box.new parent: datespage, top: 3, left: 1, width: 8, height: 1, content: "Time:"
timeedit = Widget::TimeEdit.new \
  parent: datespage, top: 3, left: 9, width: 10, height: 1,
  style: Style.new(fg: "white", bg: "#303030")

Widget::Box.new parent: datespage, top: 5, left: 1, width: 8, height: 1, content: "Ratio:"
dspin = Widget::DoubleSpinBox.new \
  parent: datespage, top: 5, left: 9, width: 10, height: 1,
  minimum: 0.0, maximum: 1.0, step: 0.05, value: 0.25,
  style: Style.new(fg: "yellow")

dateedit.on(Event::DateChange) { |e| status.set_content " date: #{e.date.to_s("%Y-%m-%d")}"; s.render }
timeedit.on(Event::DateChange) { |e| status.set_content " time: #{e.date.to_s("%H:%M:%S")}"; s.render }
dspin.on(Event::DoubleValueChange) { |e| status.set_content " ratio: #{e.value}"; s.render }

Widget::Box.new parent: datespage, bottom: 1, left: 1, width: 36, height: 2,
  content: "Click the date for a calendar; click a time section to select it. Arrows/wheel step.",
  style: Style.new(fg: "#aaaaaa")

# Stack tab: a tab-less StackedWidget that auto-cycles its pages.
stack = Widget::StackedWidget.new parent: stackpage, top: 1, left: 1, right: 1, bottom: 1
{"#2a2a4a" => "Page One", "#2a4a2a" => "Page Two", "#4a2a2a" => "Page Three"}.each do |bg, label|
  stack.add_page Widget::Box.new(
    content: "{center}#{label}\n\n(click to flip){/center}", parse_tags: true,
    style: Style.new(fg: "white", bg: bg))
end

# --- Three-pane Splitter (right) ---------------------------------------------

# Also sized by the HBox; the splitter re-evens its panes once it has a width.
split = Widget::Splitter.new \
  parent: body,
  style: Style.new(border: true)
["#202038", "#203828", "#382020"].each_with_index do |bg, i|
  split.add_pane Widget::Box.new(
    content: "{center}Pane #{i + 1}{/center}", parse_tags: true,
    style: Style.new(fg: "white", bg: bg))
end

# --- Live status from widget events ------------------------------------------

update = -> do
  status.set_content \
    " color=#{combo.value}   volume=#{slider.value}   count=#{spin.value}   angle=#{dial.value}"
  s.render
end

combo.on(Event::Action) { update.call }
slider.on(Event::ValueChange) { update.call }
spin.on(Event::ValueChange) { update.call }
dial.on(Event::ValueChange) { update.call }
update.call

# Click the stacked pages to flip through them (demonstrates StackedWidget
# without a background render loop).
stack.pages.each do |page|
  page.on(Event::Click) { stack.next_page }
end

tabs.bar.focus

s.exec
