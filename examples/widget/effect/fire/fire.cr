# Example: Crysterm::Widget::Effect::Fire
#
# Minimal, self-contained example of a single Fire.
# Run it:     crystal run examples/widget/effect/fire/fire.cr
# Maintained by tools/manage-examples.cr
require "../../example"

Crysterm::WidgetExample.run "Fire" do |screen|
  fx = Crysterm::Widget::Effect::Fire.new parent: screen, top: 0, left: 0, width: "100%", height: "100%"
  Crysterm::WidgetExample.animate_with(fx.interval) { fx.step }
end
