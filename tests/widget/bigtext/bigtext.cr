# Example: Crysterm::Widget::BigText
#
# Minimal, self-contained example of a single BigText.
# Run it:     crystal run tests/widget/bigtext/bigtext.cr
require "../example"

alias CT = Crysterm
alias CW = CT::Widgets

CT::WidgetExample.run "BigText" do |window|
  window.stylesheet = "BigText { color: #f7768e; }"
  CW::BigText.new parent: window, top: "center", left: "center", content: "Hi!"
end
