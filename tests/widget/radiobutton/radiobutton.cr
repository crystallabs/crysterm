# Example: Crysterm::Widget::RadioButton
#
# Minimal, self-contained example of a single RadioButton.
# Run it:     crystal run examples/widget/radiobutton/radiobutton.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run("RadioButton",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.6
    d.key :space, dwell: 0.9
    d.key :space, dwell: 0.9
  }) do |window|
  window.stylesheet = "RadioButton { color: #c0caf5; }"
  rb = RadioButton.new parent: window, top: "50%-1", left: "center", content: "Enable option"
  rb.focus
end
