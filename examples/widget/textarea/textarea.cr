# Example: Crysterm::Widget::TextArea
#
# Minimal, self-contained example of a single TextArea.
# Run it:     crystal run examples/widget/textarea/textarea.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run("TextArea",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.5
    d.type " edited", dwell: 0.14
    d.key :backspace, times: 7, dwell: 0.14
  }) do |screen|
  screen.stylesheet = "TextArea { border: solid; color: #c0caf5; background-color: #1f2335; }"
  ta = Crysterm::Widget::TextArea.new parent: screen, top: "center", left: "center", width: 46, height: 9
  ta.value = "A multi-line text area.\nLine two.\nLine three.\n\nEdit freely."
  ta.focus
end
