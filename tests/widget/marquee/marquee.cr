# Example: Crysterm::Widget::Marquee
#
# Minimal, self-contained example of a single Marquee.
# Run it:     crystal run tests/widget/marquee/marquee.cr
require "../example"

alias CT = Crysterm
alias CW = CT::Widgets

Crysterm::WidgetExample.run "Marquee" do |window|
  window.stylesheet = "Marquee { color: #e0af68; }"
  m = CW::Marquee.new parent: window, top: "center", left: "center", width: 40, height: 1, text: "Scrolling marquee text — Crysterm * "
  Crysterm::WidgetExample.animate_with(m.interval) { m.step }
end
