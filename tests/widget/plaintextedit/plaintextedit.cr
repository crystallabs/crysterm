# Example: Crysterm::Widget::PlainTextEdit
#
# Minimal, self-contained example of a single PlainTextEdit.
# Run it:     crystal run tests/widget/plaintextedit/plaintextedit.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run("PlainTextEdit",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.5
    d.type " edited", dwell: 0.14
    d.key :backspace, times: 7, dwell: 0.14
  }) do |window|
  window.stylesheet = "PlainTextEdit { border: solid; color: #c0caf5; background-color: #1f2335; }"
  ta = PlainTextEdit.new parent: window, top: "center", left: "center", width: 46, height: 9
  ta.value = "A multi-line text area.\nLine two.\nLine three.\n\nEdit freely."
  ta.focus
end
