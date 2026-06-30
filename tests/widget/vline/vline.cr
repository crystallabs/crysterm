# Example: Crysterm::Widget::VLine
#
# Minimal, self-contained example of a single VLine.
# Run it:     crystal run examples/widget/vline/vline.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run "VLine" do |screen|
  screen.stylesheet = "VLine { color: #7aa2f7; }"
  Crysterm::Widget::VLine.new parent: screen, left: "center", top: 2, height: 16
end
