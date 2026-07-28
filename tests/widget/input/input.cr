# Example: Crysterm::Widget::Input
#
# Minimal, self-contained example of a single Input.
# Run it:     crystal run tests/widget/input/input.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "Input" do |window|
  window.stylesheet = "Input { border: solid; color: #c0caf5; background-color: #1f2335; }"
  Input.new \
    parent: window, top: "center", left: "center", width: 38, height: 3,
    content: "An Input — the base of the text widgets"
end
