# Example: Crysterm::Widget::Marquee
#
# Minimal, self-contained example of a single Marquee.
# Run it:     crystal run examples/widget/marquee/marquee.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "Marquee" do |window|
  window.stylesheet = "Marquee { color: #e0af68; }"
  m = Marquee.new parent: window, top: "center", left: "center", width: 40, height: 1, text: "Scrolling marquee text — Crysterm * "
  Crysterm::WidgetExample.animate_with(m.interval) { m.step }
end
