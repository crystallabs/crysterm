# Example: Crysterm::Widget::ScrollableBox
#
# Minimal, self-contained example of a single ScrollableBox.
# Run it:     crystal run examples/widget/scrollable_box/scrollable_box.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run("ScrollableBox",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.5
    d.key :down, times: 8, dwell: 0.22
    d.key :up, times: 8, dwell: 0.22
  }) do |window|
  window.stylesheet = "ScrollableBox { border: solid; color: #c0caf5; }"
  sb = ScrollableBox.new \
    parent: window, top: "center", left: "center", width: 40, height: 9, scrollbar: true, keys: true,
    content: (1..30).map { |i| "Scrollable line #{i}" }.join("\n")
  sb.focus
end
