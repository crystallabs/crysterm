# Example: Crysterm::Widget::SpinBox
#
# Minimal, self-contained example of a single SpinBox.
# Run it:     crystal run examples/widget/spinbox/spinbox.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run("SpinBox",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.5
    d.key :up, times: 4, dwell: 0.35
    d.key :down, times: 4, dwell: 0.35
  }) do |screen|
  screen.stylesheet = "SpinBox { border: solid; color: #c0caf5; }"
  sb = Crysterm::Widget::SpinBox.new parent: screen, top: "center", left: "center", width: 14, height: 3, value: 42
  sb.focus
end
