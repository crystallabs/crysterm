# Example: Crysterm::Widget::ScrollableBox
#
# Minimal, self-contained example of a single ScrollableBox.
# Run it:     crystal run examples/widget/scrollable_box/scrollable_box.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run("ScrollableBox",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.5
    d.key :down, times: 8, dwell: 0.22
    d.key :up, times: 8, dwell: 0.22
  }) do |screen|
  screen.stylesheet = "ScrollableBox { border: solid; color: #c0caf5; }"
  sb = Crysterm::Widget::ScrollableBox.new \
    parent: screen, top: "center", left: "center", width: 40, height: 9, scrollbar: true, keys: true,
    content: (1..30).map { |i| "Scrollable line #{i}" }.join("\n")
  sb.focus
end
