# Example: Crysterm::Widget::BigText
#
# Minimal, self-contained example of a single BigText.
# Run it:     crystal run examples/widget/bigtext/bigtext.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run "BigText" do |screen|
  screen.stylesheet = "BigText { color: #f7768e; }"
  Crysterm::Widget::BigText.new parent: screen, top: "center", left: "center", content: "Hi!"
end
