# Example: Crysterm::Widget::Line
#
# Minimal, self-contained example of a single Line.
# Run it:     crystal run tests/widget/line/line.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "Line" do |window|
  window.stylesheet = "Line { color: #7aa2f7; }"
  Line.new parent: window, top: "center", left: 4, width: 40, orientation: :horizontal
end
