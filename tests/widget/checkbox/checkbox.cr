# Example: Crysterm::Widget::CheckBox
#
# Minimal, self-contained example of a single CheckBox.
# Run it:     crystal run tests/widget/checkbox/checkbox.cr
require "../example"

include Crysterm
include Crysterm::Widgets

WidgetExample.run("CheckBox",
  script: ->(d : WidgetExample::Driver) {
    d.hold 0.6
    4.times { d.key :space, dwell: 0.8 }
  }) do |window|
  window.stylesheet = "CheckBox { color: #c0caf5; }"
  cb = CheckBox.new parent: window, top: "center", left: "center", checked: true, content: "Enable feature"
  cb.focus
end
