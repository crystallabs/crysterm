# Example: Crysterm::Widget::VLine
#
# Minimal, self-contained example of a single VLine.
# Run it:     crystal run tests/widget/vline/vline.cr
require "../example"

alias CT = Crysterm
alias CW = CT::Widgets

Crysterm::WidgetExample.run "VLine" do |window|
  window.stylesheet = "VLine { color: #7aa2f7; }"
  CW::VLine.new parent: window, left: "center", top: 2, height: 16
end
