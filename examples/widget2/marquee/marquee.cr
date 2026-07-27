# Example: Crysterm::Widget::Marquee
#
# Minimal, self-contained example of a single Marquee.
# Run it:     crystal run examples/widget/marquee/marquee.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run "Marquee" do |screen|
  screen.stylesheet = "Marquee { color: #e0af68; }"
  m = Crysterm::Widget::Marquee.new parent: screen, top: "center", left: "center", width: 40, height: 1, text: "Scrolling marquee text — Crysterm * "
  Crysterm::WidgetExample.animate_with(m.interval) { m.step }
end
