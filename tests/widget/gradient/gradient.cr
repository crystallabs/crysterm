# Example: Crysterm::Widget::Gradient
#
# Minimal, self-contained example of a single Gradient.
# Run it:     crystal run examples/widget/gradient/gradient.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "Gradient" do |window|
  grad = Gradient.new \
    parent: window, top: 0, left: 0, width: "100%", height: "100%",
    stops: ["#ff0000", "#ffff00", "#00ff00", "#00ffff", "#0000ff", "#ff00ff"], direction: :horizontal
  Crysterm::WidgetExample.animate_with(0.08.seconds) { grad.phase += 0.06 }
end
