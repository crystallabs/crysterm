# Example: Crysterm::Widget::LineEdit
#
# Minimal, self-contained example of a single LineEdit.
# Run it:     crystal run tests/widget/lineedit/lineedit.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run("LineEdit",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.5
    d.type " more", dwell: 0.16
    d.key :backspace, times: 5, dwell: 0.16
  }) do |window|
  window.stylesheet = "LineEdit { border: solid; color: #c0caf5; background-color: #1f2335; }"
  tb = LineEdit.new parent: window, top: "center", left: "center", width: 42, height: 3
  tb.value = "Editable text — type here"
  tb.focus
end
