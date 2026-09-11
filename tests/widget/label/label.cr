# Example: Crysterm::Widget::Label
#
# Minimal, self-contained example of a single Label.
# Run it:     crystal run tests/widget/label/label.cr
require "../example"

alias CT = Crysterm
alias CW = CT::Widgets

Crysterm::WidgetExample.run "Label" do |window|
  window.stylesheet = "Label { color: #9ece6a; }"
  CW::Label.new parent: window, top: "center", left: "center", content: "A Label widget"
end
