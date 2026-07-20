# Example: Crysterm::Widget::VLine
#
# Minimal, self-contained example of a single VLine.
# Run it:     crystal run examples/widget/vline/vline.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "VLine" do |window|
  window.stylesheet = "VLine { color: #7aa2f7; }"
  VLine.new parent: window, left: "center", top: 2, height: 16
end
