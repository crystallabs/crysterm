# Example: Crysterm::Widget::Input
#
# Minimal, self-contained example of a single Input.
# Run it:     crystal run examples/widget/input/input.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run "Input" do |screen|
  screen.stylesheet = "Input { border: solid; color: #c0caf5; background-color: #1f2335; }"
  Crysterm::Widget::Input.new \
    parent: screen, top: "center", left: "center", width: 38, height: 3,
    content: "An Input — the base of the text widgets"
end
