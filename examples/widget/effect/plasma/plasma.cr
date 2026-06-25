# Example: Crysterm::Widget::Effect::Plasma
#
# Minimal, self-contained example of a single Plasma.
# Run it:     crystal run examples/widget/effect/plasma/plasma.cr
# Maintained by tools/manage-examples.cr
require "../../example"

Crysterm::WidgetExample.run "Plasma" do |screen|
  fx = Crysterm::Widget::Effect::Plasma.new parent: screen, top: 0, left: 0, width: "100%", height: "100%"
  Crysterm::WidgetExample.animate_with(fx.interval) { fx.step }
end
