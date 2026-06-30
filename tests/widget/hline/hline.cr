# Example: Crysterm::Widget::HLine
#
# Minimal, self-contained example of a single HLine.
# Run it:     crystal run examples/widget/hline/hline.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run "HLine" do |screen|
  screen.stylesheet = "HLine { color: #7aa2f7; }"
  Crysterm::Widget::HLine.new parent: screen, top: "center", left: 4, width: 40
end
