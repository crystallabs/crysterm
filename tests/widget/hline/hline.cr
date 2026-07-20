# Example: Crysterm::Widget::HLine
#
# Minimal, self-contained example of a single HLine.
# Run it:     crystal run examples/widget/hline/hline.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "HLine" do |window|
  window.stylesheet = "HLine { color: #7aa2f7; }"
  HLine.new parent: window, top: "center", left: 4, width: 40
end
