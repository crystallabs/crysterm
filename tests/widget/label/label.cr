# Example: Crysterm::Widget::Label
#
# Minimal, self-contained example of a single Label.
# Run it:     crystal run examples/widget/label/label.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "Label" do |window|
  window.stylesheet = "Label { color: #9ece6a; }"
  Label.new parent: window, top: "center", left: "center", content: "A Label widget"
end
