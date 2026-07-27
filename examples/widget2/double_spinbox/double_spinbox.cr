# Example: Crysterm::Widget::DoubleSpinBox
#
# Minimal, self-contained example of a single DoubleSpinBox.
# Run it:     crystal run examples/widget/double_spinbox/double_spinbox.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run("DoubleSpinBox",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.5
    d.key :up, times: 4, dwell: 0.35
    d.key :down, times: 4, dwell: 0.35
  }) do |screen|
  screen.stylesheet = "DoubleSpinBox { border: solid; color: #c0caf5; }"
  Crysterm::Widget::DoubleSpinBox.new parent: screen, top: "center", left: "center", width: 18, height: 3, value: 3.14, suffix: " kg"
end
