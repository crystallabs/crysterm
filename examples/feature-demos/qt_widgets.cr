# FEATURE: Qt-inspired widgets.
#
# Showcases the Qt-modeled widgets working together inside a `MainWindow`:
#   * MainWindow       — menu bar (top) + status bar (bottom) + dock + central
#   * Menu             — as a menu bar of pop-up menus (File / Edit / Help) and,
#                        in the Menu tab, nested submenus + checkable items
#   * DockWidget       — a closable/floatable "Panes" dock holding a Splitter
#   * StatusBar        — live message (left) + permanent sections (right)
#   * TabWidget        — closable pages, the window's central widget
#   * GroupBox         — checkable title disables/enables its contents
#   * Tree             — collapsible node hierarchy (Right/Left expand/collapse)
#   * ComboBox         — editable: type to filter the options
#   * Slider (w/ ticks) / SpinBox / Dial — value controls that emit events
#   * DateEdit / TimeEdit / DateTimeEdit / DoubleSpinBox — date/time + float entry
#   * ToolTip          — hover the Profile controls to see hover help
#   * StackedWidget    — auto-cycling pages (no tab bar)
#
# Everything is laid out by `MainWindow` and re-flows to the terminal size.
#
# Try it: click File/Edit/Help for pop-up menus (with one open, hover another to
# switch); hover a control for a tooltip;
# float or close the right "Panes" dock from its title bar; Tab cycles focus;
# arrows adjust the focused control; type in the ComboBox to filter; drag a
# splitter divider. Press q to quit.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "Qt-like Widgets"

# --- Main window frame -------------------------------------------------------

win = Widget::MainWindow.new parent: s, top: 0, left: 0, width: "100%", height: "100%"

status = Widget::StatusBar.new
win.status_bar = status
status.add_permanent "Tab: focus"
status.add_permanent "q: quit"

# Shared helper: an Action that reports to the status bar when triggered.
mk = ->(text : String, msg : String) do
  a = Action.new text
  a.on(Event::Triggered) { status.show_message " #{msg}"; s.render }
  a
end

# --- Menu bar (pop-up Menus) -------------------------------------------------

# A `MenuBar` packages all the open/switch/hover/highlight/keyboard wiring: click
# a title (or Enter/Down while focused) to open it, and once open, hovering or
# arrowing onto another title switches to it. Right on a submenu-less item / Left
# also move between menus.
menubar = Widget::MenuBar.new menu_style: Style.new(border: true, fg: "white", bg: "#202030"),
  style: Style.new(fg: "white", bg: "#303050")
win.menu_bar = menubar

filemenu = menubar.add_menu "File"
filemenu.add("New") { status.show_message " new file"; s.render }
filemenu.add("Open") { status.show_message " open file"; s.render }
filemenu.add_menu "Recent", [mk.call("report.txt", "open report.txt"), mk.call("notes.md", "open notes.md")]
filemenu.add_separator
filemenu.add("Quit") { status.show_message " (press q to quit)"; s.render }

editmenu = menubar.add_menu "Edit", [mk.call("Cut", "cut"), mk.call("Copy", "copy"), mk.call("Paste", "paste")]
editmenu.add_separator
ed_wrap = Action.new "Word Wrap"
ed_wrap.checkable = true
editmenu << ed_wrap

menubar.add_menu("Help").add("About") { status.show_message " Crysterm — Qt-inspired widgets"; s.render }

# --- Central tabbed area -----------------------------------------------------

tabs = Widget::TabWidget.new tabs_closable: true, style: Style.new(border: true)
win.central_widget = tabs

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

# Controls tab: a checkable GroupBox holding the value widgets (with tooltips).
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
slider.tool_tip = "Master volume (0–100)"

Widget::Box.new parent: gb, top: 3, left: 1, width: 8, height: 1, content: "Count:"
spin = Widget::SpinBox.new \
  parent: gb, top: 3, left: 9, width: 12, height: 1,
  minimum: 0, maximum: 10, value: 3, suffix: " items",
  style: Style.new(fg: "yellow")
spin.tool_tip = "Item count (type or step)"

Widget::Box.new parent: gb, top: 5, left: 1, width: 8, height: 1, content: "Angle:"
dial = Widget::Dial.new \
  parent: gb, top: 5, left: 9, width: 7, height: 3,
  minimum: 0, maximum: 360, value: 90,
  style: Style.new(fg: "magenta")
dial.tool_tip = "Angle in degrees"

# Color combo placed last so its drop-down opens *below* the other controls.
Widget::Box.new parent: gb, top: 9, left: 1, width: 8, height: 1, content: "Color:"
combo = Widget::ComboBox.new \
  parent: gb, top: 9, left: 9, width: 16, height: 1, editable: true,
  options: ["Red", "Green", "Blue", "Cyan", "Magenta", "Maroon"],
  style: Style.new(fg: "white", bg: "#303030")
combo.tool_tip = "Pick or type a color"

# Menu tab: an embedded menu with nested submenus + a checkable item.
menu = Widget::Menu.new parent: menupage, top: 1, left: 1, width: 22, height: 10,
  style: Style.new(fg: "white", border: true)

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
tree.expand src

tree.on(Event::SelectItem) { status.show_message " tree: #{tree.selected_node.try(&.text)}"; s.render }
tree.on(Event::Expand) { status.show_message " tree: expanded #{tree.selected_node.try(&.text)}"; s.render }
tree.on(Event::Collapse) { status.show_message " tree: collapsed #{tree.selected_node.try(&.text)}"; s.render }

Widget::Box.new parent: treepage, bottom: 1, left: 1, width: 34, height: 2,
  content: "Right/Left or Space expand/collapse nodes.", style: Style.new(fg: "#aaaaaa")

# Dates tab: DateEdit (calendar popup), TimeEdit, DateTimeEdit, DoubleSpinBox.
Widget::Box.new parent: datespage, top: 1, left: 1, width: 8, height: 1, content: "Date:"
dateedit = Widget::DateEdit.new \
  parent: datespage, top: 1, left: 9, width: 12, height: 1,
  style: Style.new(fg: "white", bg: "#303030")

Widget::Box.new parent: datespage, top: 3, left: 1, width: 8, height: 1, content: "Time:"
timeedit = Widget::TimeEdit.new \
  parent: datespage, top: 3, left: 9, width: 10, height: 1,
  style: Style.new(fg: "white", bg: "#303030")

Widget::Box.new parent: datespage, top: 5, left: 1, width: 8, height: 1, content: "Stamp:"
dtedit = Widget::DateTimeEdit.new \
  parent: datespage, top: 5, left: 9, width: 21, height: 1,
  style: Style.new(fg: "white", bg: "#303030")

Widget::Box.new parent: datespage, top: 7, left: 1, width: 8, height: 1, content: "Ratio:"
dspin = Widget::DoubleSpinBox.new \
  parent: datespage, top: 7, left: 9, width: 10, height: 1,
  minimum: 0.0, maximum: 1.0, step: 0.05, value: 0.25,
  style: Style.new(fg: "yellow")

dateedit.on(Event::DateChange) { |e| status.show_message " date: #{e.date.to_s("%Y-%m-%d")}"; s.render }
timeedit.on(Event::DateChange) { |e| status.show_message " time: #{e.date.to_s("%H:%M:%S")}"; s.render }
dtedit.on(Event::DateChange) { |e| status.show_message " stamp: #{e.date.to_s("%Y-%m-%d %H:%M:%S")}"; s.render }
dspin.on(Event::DoubleValueChange) { |e| status.show_message " ratio: #{e.value}"; s.render }

Widget::Box.new parent: datespage, bottom: 1, left: 1, width: 38, height: 2,
  content: "Click the date for a calendar; wheel a section to step it.",
  style: Style.new(fg: "#aaaaaa")

# Stack tab: a tab-less StackedWidget that auto-cycles its pages.
stack = Widget::StackedWidget.new parent: stackpage, top: 1, left: 1, right: 1, bottom: 1
{"#2a2a4a" => "Page One", "#2a4a2a" => "Page Two", "#4a2a2a" => "Page Three"}.each do |bg, label|
  stack.add_page Widget::Box.new(
    content: "{center}#{label}\n\n(click to flip){/center}", parse_tags: true,
    style: Style.new(fg: "white", bg: bg))
end

# --- Right dock: a Splitter inside a DockWidget ------------------------------

split = Widget::Splitter.new style: Style.new(border: true)
["#202038", "#203828", "#382020"].each_with_index do |bg, i|
  split.add_pane Widget::Box.new(
    content: "{center}Pane #{i + 1}{/center}", parse_tags: true,
    style: Style.new(fg: "white", bg: bg))
end

dock = Widget::DockWidget.new title: "Panes", area: Widget::DockWidget::Area::Right, dock_size: 30
dock.widget = split
win.add_dock dock

# --- Live status from widget events ------------------------------------------

update = -> do
  status.show_message \
    " color=#{combo.value}   volume=#{slider.value}   count=#{spin.value}   angle=#{dial.value}"
  s.render
end

combo.on(Event::Action) { update.call }
slider.on(Event::ValueChange) { update.call }
spin.on(Event::ValueChange) { update.call }
dial.on(Event::ValueChange) { update.call }
update.call

stack.pages.each do |page|
  page.on(Event::Click) { stack.next_page }
end

tabs.bar.focus

s.exec
