# Example: Crysterm::Widget::HLine
#
# Minimal, self-contained example of a single HLine.
# Run it:     crystal run tests/widget/hline/hline.cr
require "../example"

alias CT = Crysterm
alias CW = CT::Widgets

Crysterm::WidgetExample.run "HLine" do |window|
  window.stylesheet = "HLine { color: #7aa2f7; }"
  CW::HLine.new parent: window, top: "center", left: 4, width: 40
end
