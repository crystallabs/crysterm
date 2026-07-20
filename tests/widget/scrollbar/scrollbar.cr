# Example: Crysterm::Widget::ScrollBar
#
# Minimal, self-contained example of a single ScrollBar.
# Run it:     crystal run examples/widget/scrollbar/scrollbar.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "ScrollBar" do |window|
  window.stylesheet = "Box { border: solid; color: #c0caf5; } ScrollBar { color: #7aa2f7; }"
  Widget::Box.new parent: window, top: 2, left: 2, width: 42, height: 16,
    content: (1..30).map { |i| " Content line #{i}" }.join("\n")
  # Vertical scrollbar is one column wide; thumb sits at `value`.
  ScrollBar.new parent: window, top: 2, left: 45, width: 1, height: 16, orientation: :vertical, value: 35
end
