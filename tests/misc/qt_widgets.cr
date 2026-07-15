# FEATURE: Qt-inspired widgets.
#
# Showcases the Qt-modeled widgets working together inside a `MainWindow`:
#   * MainWindow       — menu bar + tool bar (top) + status bar (bottom) + dock
#   * MenuBar / Menu   — pop-up menus (File / Edit / Help); nested submenus too
#   * ToolBar          — action buttons under the menu bar (New / Open / Bold)
#   * DockWidget       — a closable/floatable "Panes" dock (resize via its ◢ grip)
#   * SizeGrip         — drag the dock's corner grip to resize it while floating
#   * StatusBar        — live message (left) + permanent sections (right)
#   * SplashScreen     — animated startup banner (auto-dismisses; click/key to skip)
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
#   * Completer        — type-ahead autocomplete attached to a LineEdit
#   * ColorDialog      — modal palette picker that recolors a swatch
#   * DialogButtonBox  — standard Ok/Apply/Cancel buttons with accept/reject roles
#
# Everything is laid out by `MainWindow` and re-flows to the terminal size.
#
# Styling note: this example sets no inline styles — every color and border
# comes from the active theme (built-in `terminal`/`dark`/`light`, or a Qt
# theme via `--colors-stylesheet data/css/<name>.qss`). An inline
# `Style.new(...)` would sit at the top cascade tier and override the theme.
#
# Try it: wait for the splash to clear; click File/Edit/Help for pop-up menus
# (clicking the open menu's title again closes it; with one open, hover another
# to switch); use the tool-bar buttons; hover a control for a tooltip; drag the
# floating "Panes" dock by its title bar to move it and its ◢ corner to resize
# (its ⇕ button re-docks it right); Tab cycles focus; arrows adjust the focused
# control; type in the ComboBox to filter; drag a splitter divider; click a tab's
# ✕ to close it. On the "Extras" tab, toggle the Mode buttons, type into "Lang"
# to autocomplete, press "Pick" for the color dialog, and click the
# Ok/Apply/Cancel box. Press q to quit.

require "../../src/crysterm"

include Crysterm

s = Window.new title: "Qt-like Widgets"
# Join touching/overlapping borders into seamless junctions (├ ┬ ┼ …), e.g.
# where a submenu's left border overlaps its parent's right border.
s.dock_borders = true

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

# A `MenuBar` packages all the open/switch/hover/highlight/keyboard wiring:
# click a title (or Enter/Down while focused) to open it; once open, hovering
# or arrowing onto another title switches to it. Right/Left also move between menus.
menubar = Widget::MenuBar.new
win.menu_bar = menubar

filemenu = menubar.add_menu "File"
filemenu.add("New") { status.show_message " new file"; s.render }
filemenu.add("Open") { status.show_message " open file"; s.render }
# Recent holds two files plus a nested "Bucket" submenu: File → Recent → Bucket → (entries).
bucket = Action.new "Bucket"
bucket.menu = [mk.call("old-1.txt", "open old-1.txt"), mk.call("old-2.txt", "open old-2.txt")]
filemenu.add_submenu "Recent", [mk.call("report.txt", "open report.txt"), mk.call("notes.md", "open notes.md"), bucket]
filemenu.add_separator
filemenu.add("Quit") { s.destroy; exit }

editmenu = menubar.add_menu "Edit", [mk.call("Cut", "cut"), mk.call("Copy", "copy"), mk.call("Paste", "paste")]
editmenu.add_separator
ed_wrap = Action.new "Word Wrap"
ed_wrap.checkable = true
editmenu << ed_wrap

menubar.add_menu("Help").add("About") { status.show_message " Crysterm — Qt-inspired widgets"; s.render }

# --- Tool bar (action buttons) -----------------------------------------------

toolbar = Widget::ToolBar.new
win.add_tool_bar toolbar
toolbar.add_button("New") { status.show_message " new file"; s.render }
toolbar.add_button("Open") { status.show_message " open file"; s.render }
toolbar.add_separator
tb_bold = Action.new "Bold"
tb_bold.checkable = true
tb_bold.tool_tip = "Toggle bold"
tb_bold.on(Event::Triggered) { status.show_message " bold = #{tb_bold.checked?}"; s.render }
toolbar.add_action tb_bold

# --- Central tabbed area -----------------------------------------------------

tabs = Widget::TabWidget.new tabs_closable: true
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
  title: "Profile", checkable: true, checked: true

Widget::Box.new parent: gb, top: 1, left: 1, width: 8, height: 1, content: "Volume:"
slider = Widget::Slider.new \
  parent: gb, top: 1, left: 9, width: 16, height: 2,
  minimum: 0, maximum: 100, value: 40, show_value: true,
  tick_position: Widget::Slider::TickPosition::Below, tick_interval: 20
slider.tool_tip = "Master volume (0–100)"

Widget::Box.new parent: gb, top: 3, left: 1, width: 8, height: 1, content: "Count:"
spin = Widget::SpinBox.new \
  parent: gb, top: 3, left: 9, width: 12, height: 1,
  minimum: 0, maximum: 10, value: 3, suffix: " items"
spin.tool_tip = "Item count (type or step)"

Widget::Box.new parent: gb, top: 5, left: 1, width: 8, height: 1, content: "Angle:"
dial = Widget::Dial.new \
  parent: gb, top: 5, left: 9, width: 7, height: 3,
  minimum: 0, maximum: 360, value: 90
dial.tool_tip = "Angle in degrees"

# Color combo placed last so its drop-down opens *below* the other controls.
Widget::Box.new parent: gb, top: 9, left: 1, width: 8, height: 1, content: "Color:"
combo = Widget::ComboBox.new \
  parent: gb, top: 9, left: 9, width: 16, height: 1, editable: true,
  options: ["Red", "Green", "Blue", "Cyan", "Magenta", "Maroon"]
combo.tool_tip = "Pick or type a color"

# A seven-segment LCD mirroring the volume slider, updated on its events.
Widget::Box.new parent: gb, top: 11, left: 1, width: 8, height: 1, content: "Vol:"
lcd = Widget::LCDNumber.new \
  parent: gb, top: 11, left: 9, width: 16, height: 3, digit_count: 3
lcd.display slider.value

# Menu tab: an embedded menu with nested submenus + a checkable item.
menu = Widget::Menu.new parent: menupage, top: 1, left: 1, width: 22, height: 10

recent = Action.new "Recent"
recent.menu = [mk.call("report.txt", "open report.txt"), mk.call("notes.md", "open notes.md")]
file = Action.new "File"
file.menu = [mk.call("New", "new file"), mk.call("Open", "open file"), recent]

wrap = Action.new "Word Wrap"
wrap.checkable = true

menu << file
menu.add_separator
menu << wrap
menu << mk.call("About", "about")

Widget::Box.new parent: menupage, bottom: 1, left: 1, width: 34, height: 2,
  content: "Right opens a submenu, Left closes it."

# Tree tab: a collapsible node hierarchy.
tree = Widget::Tree.new parent: treepage, top: 1, left: 1, right: 1, bottom: 3
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
  content: "Right/Left or Space expand/collapse nodes."

# Dates tab: DateEdit (calendar popup), TimeEdit, DateTimeEdit, DoubleSpinBox.
Widget::Box.new parent: datespage, top: 1, left: 1, width: 8, height: 1, content: "Date:"
dateedit = Widget::DateEdit.new \
  parent: datespage, top: 1, left: 9, width: 12, height: 1

Widget::Box.new parent: datespage, top: 3, left: 1, width: 8, height: 1, content: "Time:"
timeedit = Widget::TimeEdit.new \
  parent: datespage, top: 3, left: 9, width: 10, height: 1

Widget::Box.new parent: datespage, top: 5, left: 1, width: 8, height: 1, content: "Stamp:"
dtedit = Widget::DateTimeEdit.new \
  parent: datespage, top: 5, left: 9, width: 21, height: 1

Widget::Box.new parent: datespage, top: 7, left: 1, width: 8, height: 1, content: "Ratio:"
dspin = Widget::DoubleSpinBox.new \
  parent: datespage, top: 7, left: 9, width: 10, height: 1,
  minimum: 0.0, maximum: 1.0, step: 0.05, value: 0.25

dateedit.on(Event::DateChanged) { |e| status.show_message " date: #{e.date.to_s("%Y-%m-%d")}"; s.render }
timeedit.on(Event::DateChanged) { |e| status.show_message " time: #{e.date.to_s("%H:%M:%S")}"; s.render }
dtedit.on(Event::DateChanged) { |e| status.show_message " stamp: #{e.date.to_s("%Y-%m-%d %H:%M:%S")}"; s.render }
dspin.on(Event::DoubleValueChanged) { |e| status.show_message " ratio: #{e.value}"; s.render }

# A standalone Calendar (QCalendarWidget): the nav bar pages months (‹/›),
# pops up a month menu (click name) and year menu (click year), with ISO week
# numbers down the left. Arrow keys move the selection.
cal = Widget::Calendar.new \
  parent: datespage, top: 1, left: 30, width: 25, height: 10
cal.vertical_header_format = Widget::Calendar::VerticalHeaderFormat::ISOWeekNumbers
cal.on(Event::DateChanged) { |e| status.show_message " calendar: #{e.date.to_s("%Y-%m-%d")}"; s.render }
cal.on(Event::CurrentPageChanged) { |e| status.show_message " page: #{e.year}-#{e.month.to_s.rjust(2, '0')}"; s.render }

Widget::Box.new parent: datespage, bottom: 1, left: 1, width: 54, height: 2,
  content: "Click the date field for a calendar; click the calendar's month/year to pick. Wheel a section to step it."

# Stack tab: a tab-less StackedWidget that auto-cycles its pages.
stack = Widget::StackedWidget.new parent: stackpage, top: 1, left: 1, right: 1, bottom: 1
["Page One", "Page Two", "Page Three"].each do |label|
  stack.add_page Widget::Box.new(
    content: "{center}#{label}\n\n(click to flip){/center}", parse_tags: true)
end

# Extras tab: ButtonGroup (exclusive toggle buttons), ToolButton (default
# action + popup menu), Completer (autocomplete on a LineEdit), ColorDialog
# (modal picker), and DialogButtonBox (standard buttons).

# Exclusive ButtonGroup: three checkable buttons of which only one stays "on".
mode_labels = %w[Low Mid High]
Widget::Box.new parent: extraspage, top: 1, left: 1, width: 9, height: 1, content: "Mode:"
bgroup = ButtonGroup.new
mode_labels.each_with_index do |label, i|
  b = Widget::Button.new \
    parent: extraspage, top: 1, left: 10 + i * 8, width: 7, height: 1,
    content: label, align: :center, checkable: true, focus_on_click: true
  bgroup.add b, i
end
bgroup.on(Event::ButtonClick) do
  # Mark the checked button by bracketing its label: a plain Button has no
  # built-in checked glyph, and a direct `style.bg=` would be undone by the CSS
  # cascade on the next render, but content is outside the cascade.
  bgroup.buttons.each_with_index do |b, i|
    btn = b.as(Widget::Button)
    btn.set_content(btn.checked? ? "[#{mode_labels[i]}]" : mode_labels[i])
  end
  status.show_message " mode = #{bgroup.checked_id}"
  s.render
end

# ToolButton with a default Action (Enter/Space applies it) and a popup Menu
# (press Down to open it), like a Qt tool button with a drop-down.
tb_menu = Widget::Menu.new parent: s, width: 16, height: 4
tb_menu.add("Rename") { status.show_message " tool: rename"; s.render }
tb_menu.add("Delete") { status.show_message " tool: delete"; s.render }
tb_menu.hide # stays hidden until opened from the ToolButton (via Down)

tool_action = Action.new "Apply"
tool_action.on(Event::Triggered) { status.show_message " tool: apply"; s.render }

Widget::Box.new parent: extraspage, top: 3, left: 1, width: 9, height: 1, content: "Tool:"
toolbtn = Widget::ToolButton.new \
  parent: extraspage, top: 3, left: 10, width: 12, height: 1,
  action: tool_action, menu: tb_menu, align: :center
toolbtn.tool_tip = "Enter/Space applies; Down opens the menu"

# Completer: type into the LineEdit to autocomplete from a fixed word list.
Widget::Box.new parent: extraspage, top: 5, left: 1, width: 9, height: 1, content: "Lang:"
langbox = Widget::LineEdit.new \
  parent: extraspage, top: 5, left: 10, width: 18, height: 1
langbox.tool_tip = "Type to autocomplete (Down opens the list, Tab/Enter accepts)"
completer = Completer.new %w[Crystal Ruby Rust Python Perl PHP Go Groovy Java JavaScript Kotlin Lua]
completer.attach langbox

# ColorDialog: a modal palette picker launched from a button. The picked color
# is reported in the status bar; with no inline style on the swatch, the
# theme's `Box` rule paints its surface (see the ButtonGroup note above).
swatch = Widget::Box.new parent: extraspage, top: 7, left: 18, width: 6, height: 1
colordlg = Widget::ColorDialog.new \
  parent: s, top: "center", left: "center", width: 56, height: 20
colordlg.hide
Widget::Box.new parent: extraspage, top: 7, left: 1, width: 9, height: 1, content: "Color:"
pickbtn = Widget::Button.new \
  parent: extraspage, top: 7, left: 10, width: 6, height: 1,
  content: "Pick", align: :center, focus_on_click: true
open_picker = -> do
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
# Both the "Pick" button and a click on the color swatch itself open the picker.
pickbtn.on(Event::Press) { open_picker.call }
swatch.on(Event::Click) { open_picker.call }

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

# --- Floating dock: a Splitter inside a DockWidget ---------------------------

split = Widget::Splitter.new
3.times do |i|
  split.add_pane Widget::Box.new(
    content: "{center}Pane #{i + 1}{/center}", parse_tags: true)
end

# The dock's home is the right edge (width `dock_size`), but we immediately
# float it as a compact, freely-draggable panel. Grab the "Panes" title bar to
# move it, drag its ◢ corner grip to resize; its ⇕ title button docks it back
# to the right, and dragging a docked dock's title bar floats it again.
dock = Widget::DockWidget.new title: "Panes", area: Widget::DockWidget::Area::Right, dock_size: 30
dock.widget = split
win.add_dock dock
dock.toggle_floating
dock.top = 4; dock.left = 40; dock.width = 34; dock.height = 15

# A corner grip resizes the dock while it's floating (when docked, MainWindow
# re-imposes the dock's size each frame).
Widget::SizeGrip.new parent: dock, bottom: 0, right: 0, width: 1, height: 1, min_drag_width: 12, min_drag_height: 4

# --- Live status from widget events ------------------------------------------

update = -> do
  status.show_message \
    " color=#{combo.value}   volume=#{slider.value}   count=#{spin.value}   angle=#{dial.value}"
  s.render
end

combo.on(Event::Action) { update.call }
slider.on(Event::ValueChanged) { lcd.display slider.value; update.call }
spin.on(Event::ValueChanged) { update.call }
dial.on(Event::ValueChanged) { update.call }
update.call

stack.pages.each do |page|
  page.on(Event::Click) { stack.next_page }
end

tabs.bar.focus

# --- Splash screen (animated, auto-dismisses) --------------------------------

# A centered overlay holding a scrolling rainbow banner (a `Marquee` drives its
# own animation fiber via `#start`); clears itself after a couple seconds.
splash_banner = Widget::Marquee.new text: "  ✦  Crysterm — Qt-inspired terminal widgets  ✦  ", rainbow: true
splash = Widget::SplashScreen.new \
  parent: s, width: 46, height: 7,
  content: splash_banner
splash.show_message "Loading…"
splash_banner.start
splash.on(Event::Complete) { splash_banner.stop }
splash.finish_after 2.seconds

s.exec
