# Example: Crysterm::Widget::CommandBar
#
# Minimal, self-contained example of a single CommandBar.
# Run it:     crystal run tests/widget/command_bar/command_bar.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run("CommandBar",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.5
    d.key :right, times: 4, dwell: 0.35
    d.key :left, times: 4, dwell: 0.35
  }) do |window|
  window.stylesheet = "CommandBar { color: #c0caf5; }"
  # `keys: true` opts into keyboard navigation (see the class docs) — without
  # it the bar never registers as keyable and the scripted arrows do nothing.
  lb = CommandBar.new parent: window, top: "center", left: 0, width: "100%", height: 1,
    mouse: true, keys: true
  lb.items = ["File", "Edit", "View", "Tools", "Help"]
  lb.focus
end
