# Example: Crysterm::Widget::BigText
#
# Minimal, self-contained example of a single BigText.
# Run it:     crystal run examples/widget/bigtext/bigtext.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

WidgetExample.run "BigText" do |window|
  window.stylesheet = "BigText { color: #f7768e; }"
  BigText.new parent: window, top: "center", left: "center", content: "Hi!"
end
