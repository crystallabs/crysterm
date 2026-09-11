# Example: Crysterm::Widget::Line
#
# Minimal, self-contained example of a single Line.
# Run it:     crystal run tests/widget/line/line.cr
require "../example"

alias CT = Crysterm
alias CW = CT::Widgets

Crysterm::WidgetExample.run "Line" do |window|
  window.stylesheet = "Line { color: #7aa2f7; }"
  CW::Line.new parent: window, top: "center", left: 4, width: 40, orientation: :horizontal
end
