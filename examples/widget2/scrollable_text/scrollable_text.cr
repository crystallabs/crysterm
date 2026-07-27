# Example: Crysterm::Widget::ScrollableText
#
# Minimal, self-contained example of a single ScrollableText.
# Run it:     crystal run examples/widget/scrollable_text/scrollable_text.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run("ScrollableText",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.5
    d.key :down, times: 8, dwell: 0.22
    d.key :up, times: 8, dwell: 0.22
  }) do |screen|
  screen.stylesheet = "ScrollableText { border: solid; color: #c0caf5; }"
  st = Crysterm::Widget::ScrollableText.new \
    parent: screen, top: "center", left: "center", width: 44, height: 9, scrollbar: true, keys: true,
    content: (1..40).map { |i| "Scrollable text line #{i}" }.join("\n")
  st.focus
end
