# Example: Crysterm::Widget::Label
#
# Minimal, self-contained example of a single Label.
# Run it:     crystal run examples/widget/label/label.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run "Label" do |screen|
  screen.stylesheet = "Label { color: #9ece6a; }"
  Crysterm::Widget::Label.new parent: screen, top: "center", left: "center", content: "A Label widget"
end
