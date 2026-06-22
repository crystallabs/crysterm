# FEATURE: Qt-inspired widgets.
#
# Showcases the Qt-modeled widgets working together:
#   * TabWidget        — pages "Controls" / "Menu" / "Tree" / "Stack"
#   * GroupBox         — checkable title disables/enables its contents
#   * Tree             — collapsible node hierarchy (Right/Left expand/collapse)
#   * ComboBox         — editable: type to filter the options
#   * Slider / SpinBox / Dial — value controls that emit events
#   * Menu             — with nested submenus (File ▶ Recent ▶ …)
#   * StackedWidget    — auto-cycling pages (no tab bar)
#   * Splitter         — three panes with draggable dividers
#
# The status bar updates live from the widgets' Action/ValueChange events.
#
# Try it: Tab cycles focus; arrows adjust the focused Slider/SpinBox/Dial; type
# in the ComboBox to filter; in the Menu, Right opens a submenu and Left closes
# it; drag a splitter divider (or focus it and use the arrows). Press q to quit.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "Qt-like Widgets"
s.show_fps = nil

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Qt-inspired widgets — click a control to focus it · arrows adjust · type filters the combo · q quits{/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#303050")

status = Widget::Box.new \
  parent: s, bottom: 0, left: 0, width: "100%", height: 1,
  style: Style.new(fg: "black", bg: "cyan")

# --- Tabbed area (left) ------------------------------------------------------

tabs = Widget::TabWidget.new \
  parent: s, top: 2, left: 1, width: 40, height: 20,
  style: Style.new(border: true)

controls = Widget::Box.new
menupage = Widget::Box.new
treepage = Widget::Box.new
stackpage = Widget::Box.new
tabs.add_tab "Controls", controls
tabs.add_tab "Menu", menupage
tabs.add_tab "Tree", treepage
tabs.add_tab "Stack", stackpage

# Controls tab: a checkable GroupBox holding the value widgets.
gb = Widget::GroupBox.new \
  parent: controls, top: 1, left: 1, width: 36, height: 12,
  title: "Profile", checkable: true, checked: true,
  style: Style.new(fg: "white", border: true)

Widget::Box.new parent: gb, top: 1, left: 1, width: 8, height: 1, content: "Volume:"
slider = Widget::Slider.new \
  parent: gb, top: 1, left: 9, width: 16, height: 1,
  minimum: 0, maximum: 100, value: 40, show_value: true,
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
tree = Widget::Tree.new parent: treepage, top: 1, left: 1, width: 34, height: 11,
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

# Stack tab: a tab-less StackedWidget that auto-cycles its pages.
stack = Widget::StackedWidget.new parent: stackpage, top: 1, left: 1, width: 34, height: 12
{"#2a2a4a" => "Page One", "#2a4a2a" => "Page Two", "#4a2a2a" => "Page Three"}.each do |bg, label|
  stack.add_page Widget::Box.new(
    content: "{center}#{label}\n\n(click to flip){/center}", parse_tags: true,
    style: Style.new(fg: "white", bg: bg))
end

# --- Three-pane Splitter (right) ---------------------------------------------

split = Widget::Splitter.new \
  parent: s, top: 2, left: 42, width: 36, height: 20,
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
