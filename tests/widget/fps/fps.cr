# Example: Crysterm::Widget::Fps
#
# Minimal, self-contained example of a single Fps.
# Run it:     crystal run tests/widget/fps/fps.cr
require "../example"

alias CT = Crysterm
alias CW = CT::Widgets

Crysterm::WidgetExample.run "Fps" do |window|
  window.stylesheet = "Fps { border: solid; color: #9ece6a; }"
  CW::FPS.new parent: window, top: "center", left: "center", width: 30, height: 5
end
