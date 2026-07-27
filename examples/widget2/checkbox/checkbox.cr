# Example: Crysterm::Widget::CheckBox
#
# Minimal, self-contained example of a single CheckBox.
# Run it:     crystal run examples/widget/checkbox/checkbox.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run("CheckBox",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.6
    4.times { d.key :space, dwell: 0.8 }
  }) do |screen|
  screen.stylesheet = "Checkbox { color: #c0caf5; }"
  cb = Crysterm::Widget::CheckBox.new parent: screen, top: "center", left: "center", checked: true, content: "Enable feature"
  cb.focus
end
