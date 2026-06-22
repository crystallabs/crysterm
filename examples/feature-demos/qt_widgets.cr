# FEATURE: Qt-inspired widgets.
#
# Showcases six widgets modeled after Qt: a `TabWidget` holding the form, a
# `GroupBox` whose checkable title enables/disables its contents, and the
# `ComboBox`, `Slider` and `SpinBox` controls inside it — plus a `Splitter`
# with a draggable divider on the right. The status bar updates live from the
# widgets' `Action`/`ValueChange` events.
#
# Try it: Tab cycles focus; arrows adjust the focused Slider/SpinBox; Enter (or
# a click) opens the ComboBox; drag the splitter's divider (or focus it and use
# the arrows); click the GroupBox title to disable/enable the form. Press q to
# quit.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "Qt-like Widgets"
s.show_fps = nil

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Qt-inspired widgets — Tab: focus · arrows: adjust · Enter: combo · q: quit{/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#303050")

status = Widget::Box.new \
  parent: s, bottom: 0, left: 0, width: "100%", height: 1,
  style: Style.new(fg: "black", bg: "cyan")

# --- Tabbed form (left) ------------------------------------------------------

tabs = Widget::TabWidget.new \
  parent: s, top: 2, left: 1, width: 38, height: 18,
  style: Style.new(border: true)

form = Widget::Box.new
info = Widget::Box.new parse_tags: true
tabs.add_tab "Form", form
tabs.add_tab "Info", info

# A checkable GroupBox; unchecking its title disables the controls inside it.
gb = Widget::GroupBox.new \
  parent: form, top: 1, left: 1, width: 34, height: 9,
  title: "Profile", checkable: true, checked: true,
  style: Style.new(fg: "white", border: true)

Widget::Box.new parent: gb, top: 1, left: 1, width: 8, height: 1, content: "Color:"
combo = Widget::ComboBox.new \
  parent: gb, top: 1, left: 9, width: 20, height: 1,
  options: ["Red", "Green", "Blue", "Cyan", "Magenta"],
  style: Style.new(fg: "white", bg: "#303030")

Widget::Box.new parent: gb, top: 3, left: 1, width: 8, height: 1, content: "Volume:"
slider = Widget::Slider.new \
  parent: gb, top: 3, left: 9, width: 20, height: 1,
  minimum: 0, maximum: 100, value: 40, show_value: true,
  style: Style.new(fg: "green")

Widget::Box.new parent: gb, top: 5, left: 1, width: 8, height: 1, content: "Count:"
spin = Widget::SpinBox.new \
  parent: gb, top: 5, left: 9, width: 12, height: 1,
  minimum: 0, maximum: 10, value: 3, suffix: " items",
  style: Style.new(fg: "yellow")

info.set_content \
  "{bold}TabWidget{/bold} holds these two pages.\n\n" \
  "{bold}GroupBox{/bold} groups the controls — click\n" \
  "its title to disable/enable them.\n\n" \
  "{bold}ComboBox{/bold}, {bold}Slider{/bold} and {bold}SpinBox{/bold}\n" \
  "emit events shown in the status bar."

# --- Splitter (right) --------------------------------------------------------

split = Widget::Splitter.new \
  parent: s, top: 2, left: 40, width: 38, height: 18,
  position: 18, style: Style.new(border: true)

left_pane = Widget::Box.new \
  content: "{center}Left pane{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#202038")
right_pane = Widget::Box.new \
  content: "{center}Right pane{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#382020")
split.split left_pane, right_pane

# --- Live status from widget events ------------------------------------------

update = -> do
  status.set_content \
    " color=#{combo.value}   volume=#{slider.value}   count=#{spin.value}   split=#{split.position}"
  s.render
end

combo.on(Event::Action) { update.call }
slider.on(Event::ValueChange) { update.call }
spin.on(Event::ValueChange) { update.call }
update.call

# Start with the tab bar focused so Tab/arrows act immediately.
tabs.bar.focus

s.exec
