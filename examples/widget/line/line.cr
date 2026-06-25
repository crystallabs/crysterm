# Example: Crysterm::Widget::Line
#
# Minimal, self-contained example of a single Line.
# Run it:     crystal run examples/widget/line/line.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run "Line" do |screen|
  screen.stylesheet = "Line { color: #7aa2f7; }"
  Crysterm::Widget::Line.new parent: screen, top: "center", left: 4, width: 40, orientation: :horizontal
end
