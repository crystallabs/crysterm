# FEATURE: Qt-inspired widgets.
#
# Showcases the Qt-modeled widgets working together inside a `MainWindow`:
#   * MainWindow       — menu bar + tool bar (top) + status bar (bottom) + dock
#   * MenuBar / Menu   — pop-up menus (File / Edit / Help); nested submenus too
#   * ToolBar          — action buttons under the menu bar (New / Open / Bold)
#   * DockWidget       — a closable/floatable "Panes" dock (resize via its ◢ grip)
#   * SizeGrip         — drag the dock's corner grip to resize it while floating
#   * StatusBar        — live message (left) + permanent sections (right)
#   * SplashScreen     — animated startup banner (auto-dismisses)
#   * TabWidget        — closable pages, the window's central widget
#   * GroupBox         — checkable title disables/enables its contents
#   * LCDNumber        — seven-segment readout mirroring the volume slider
#   * Tree             — collapsible node hierarchy (Right/Left expand/collapse)
#   * ComboBox         — editable: type to filter the options
#   * Slider (w/ ticks) / SpinBox / Dial — value controls that emit events
#   * DateEdit / TimeEdit / DateTimeEdit / DoubleSpinBox — date/time + float entry
#   * ToolTip          — hover the Profile controls to see hover help
#   * StackedWidget    — auto-cycling pages (no tab bar)
#   * ButtonGroup      — exclusive toggle buttons (only one stays on)
#   * ToolButton       — a default Action plus a Down-key popup menu
#   * Completer        — type-ahead autocomplete attached to a TextBox
#   * ColorDialog      — modal palette picker that recolors a swatch
#   * DialogButtonBox  — standard Ok/Apply/Cancel buttons with accept/reject roles
#
# Everything is laid out by `MainWindow` and re-flows to the terminal size.
#
# Try it: wait for the splash to clear; click File/Edit/Help for pop-up menus
# (with one open, hover another to switch); use the tool-bar buttons; hover a
# control for a tooltip; float the right "Panes" dock from its title bar and drag
# its ◢ corner to resize; Tab cycles focus; arrows adjust the focused control;
# type in the ComboBox to filter; drag a splitter divider. On the "Extras" tab,
# toggle the Mode buttons, type into "Lang" to autocomplete, press "Pick" for the
# color dialog, and click the Ok/Apply/Cancel box. Press q to quit.

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

# --- Tool bar (action buttons) -----------------------------------------------

toolbar = Widget::ToolBar.new style: Style.new(fg: "white", bg: "#252540")
win.tool_bar = toolbar
toolbar.add_button("New") { status.show_message " new file"; s.render }
toolbar.add_button("Open") { status.show_message " open file"; s.render }
toolbar.add_separator
tb_bold = Action.new "Bold"
tb_bold.checkable = true
tb_bold.tool_tip = "Toggle bold"
tb_bold.on(Event::Triggered) { status.show_message " bold = #{tb_bold.checked?}"; s.render }
toolbar.add_action tb_bold

# --- Central tabbed area -----------------------------------------------------

tabs = Widget::TabWidget.new tabs_closable: true, style: Style.new(border: true)
win.central_widget = tabs

controls = Widget::Box.new
menupage = Widget::Box.new
treepage = Widget::Box.new
datespage = Widget::Box.new
stackpage = Widget::Box.new
extraspage = Widget::Box.new
tabs.add_tab "Controls", controls
tabs.add_tab "Menu", menupage
tabs.add_tab "Tree", treepage
tabs.add_tab "Dates", datespage
tabs.add_tab "Stack", stackpage
tabs.add_tab "Extras", extraspage

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

# A seven-segment LCD mirroring the volume slider, updated on its events.
Widget::Box.new parent: gb, top: 11, left: 1, width: 8, height: 1, content: "Vol:"
lcd = Widget::LCDNumber.new \
  parent: gb, top: 11, left: 9, width: 16, height: 3, digit_count: 3,
  style: Style.new(fg: "green")
lcd.display slider.value

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

# Extras tab: the newest Qt-modeled widgets — ButtonGroup (exclusive toggle
# buttons), ToolButton (default action + popup menu), Completer (autocomplete on
# a TextBox), ColorDialog (modal picker), and DialogButtonBox (standard buttons).

# Exclusive ButtonGroup: three checkable buttons of which only one stays "on".
Widget::Box.new parent: extraspage, top: 1, left: 1, width: 9, height: 1, content: "Mode:"
bgroup = ButtonGroup.new
%w[Low Mid High].each_with_index do |label, i|
  b = Widget::Button.new \
    parent: extraspage, top: 1, left: 10 + i * 8, width: 6, height: 1,
    content: label, align: :center, checkable: true, focus_on_click: true,
    style: Style.new(fg: "white", bg: "#303050")
  bgroup.add b, i
end
bgroup.on(Event::ButtonClick) do
  # Highlight the checked button (a plain Button shows no check glyph on its own).
  bgroup.buttons.each do |b|
    b.style.bg = b.as(Widget::Button).checked? ? "#3060a0" : "#303050"
  end
  status.show_message " mode = #{bgroup.checked_id}"
  s.render
end

# ToolButton with a default Action (Enter/Space applies it) and a popup Menu
# (press Down to open it), like a Qt tool button with a drop-down.
tb_menu = Widget::Menu.new parent: s, width: 16, height: 4, style: Style.new(fg: "white", border: true)
tb_menu.add("Rename") { status.show_message " tool: rename"; s.render }
tb_menu.add("Delete") { status.show_message " tool: delete"; s.render }
tb_menu.hide # stays hidden until opened from the ToolButton (via Down)

tool_action = Action.new "Apply"
tool_action.on(Event::Triggered) { status.show_message " tool: apply"; s.render }

Widget::Box.new parent: extraspage, top: 3, left: 1, width: 9, height: 1, content: "Tool:"
toolbtn = Widget::ToolButton.new \
  parent: extraspage, top: 3, left: 10, width: 12, height: 1,
  action: tool_action, menu: tb_menu, align: :center,
  style: Style.new(fg: "white", bg: "#252540")
toolbtn.tool_tip = "Enter/Space applies; Down opens the menu"

# Completer: type into the TextBox to autocomplete from a fixed word list.
Widget::Box.new parent: extraspage, top: 5, left: 1, width: 9, height: 1, content: "Lang:"
langbox = Widget::TextBox.new \
  parent: extraspage, top: 5, left: 10, width: 18, height: 1,
  style: Style.new(fg: "white", bg: "#303030")
langbox.tool_tip = "Type to autocomplete (Down opens the list, Tab/Enter accepts)"
completer = Completer.new %w[Crystal Ruby Rust Python Perl PHP Go Groovy Java JavaScript Kotlin Lua]
completer.attach langbox

# ColorDialog: a modal palette picker launched from a button; the chosen color
# recolors the swatch next to it.
swatch = Widget::Box.new parent: extraspage, top: 7, left: 18, width: 6, height: 1,
  style: Style.new(bg: "red")
colordlg = Widget::ColorDialog.new \
  parent: s, top: "center", left: "center", width: 50, height: 18,
  style: Style.new(fg: "white", border: true)
colordlg.hide
Widget::Box.new parent: extraspage, top: 7, left: 1, width: 9, height: 1, content: "Color:"
pickbtn = Widget::Button.new \
  parent: extraspage, top: 7, left: 10, width: 6, height: 1,
  content: "Pick", align: :center, focus_on_click: true,
  style: Style.new(fg: "white", bg: "#303050")
pickbtn.on(Event::Press) do
  colordlg.pick do |color|
    if color
      swatch.style.bg = color
      status.show_message " color = #{color}"
    else
      status.show_message " color: cancelled"
    end
    s.render
  end
  s.render
end

# DialogButtonBox: standard buttons with the right roles wired to accept/reject.
dbb = Widget::DialogButtonBox.new \
  parent: extraspage, bottom: 1, left: 1, height: 1,
  buttons: Widget::DialogButtonBox::StandardButton::Ok |
           Widget::DialogButtonBox::StandardButton::Apply |
           Widget::DialogButtonBox::StandardButton::Cancel
dbb.on(Event::Accepted) { status.show_message " dialog: accepted"; s.render }
dbb.on(Event::Rejected) { status.show_message " dialog: rejected"; s.render }
dbb.button(Widget::DialogButtonBox::StandardButton::Apply).try &.on(Event::Press) do
  status.show_message " dialog: apply"; s.render
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

# A corner grip resizes the dock while it's floating (when docked, MainWindow
# re-imposes the dock's size each frame).
Widget::SizeGrip.new parent: dock, bottom: 0, right: 0, width: 1, height: 1, min_width: 12, min_height: 4

# --- Live status from widget events ------------------------------------------

update = -> do
  status.show_message \
    " color=#{combo.value}   volume=#{slider.value}   count=#{spin.value}   angle=#{dial.value}"
  s.render
end

combo.on(Event::Action) { update.call }
slider.on(Event::ValueChange) { lcd.display slider.value; update.call }
spin.on(Event::ValueChange) { update.call }
dial.on(Event::ValueChange) { update.call }
update.call

stack.pages.each do |page|
  page.on(Event::Click) { stack.next_page }
end

tabs.bar.focus

# --- Splash screen (animated, auto-dismisses) --------------------------------

# A centered overlay holding a scrolling rainbow banner (a `Marquee` drives its
# own animation fiber via `#start`); it clears itself after a couple of seconds,
# revealing the UI behind it.
splash_banner = Widget::Marquee.new text: "  ✦  Crysterm — Qt-inspired terminal widgets  ✦  ", rainbow: true
splash = Widget::SplashScreen.new \
  parent: s, width: 46, height: 7,
  content: splash_banner, style: Style.new(border: true, fg: "white", bg: "#101028")
splash.show_message "Loading…"
splash_banner.start
splash.on(Event::Complete) { splash_banner.stop }
splash.finish_after 2.seconds

s.exec
