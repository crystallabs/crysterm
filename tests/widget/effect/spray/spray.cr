# Example: Crysterm::Widget::Effect::Spray
#
# Minimal, self-contained example of a single Spray.
# Run it:     crystal run examples/widget/effect/spray/spray.cr
# Maintained by tools/manage-examples.cr
require "../../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "Spray" do |window|
  fx = EffectSpray.new parent: window, top: 0, left: 0, width: "100%", height: "100%"
  Crysterm::WidgetExample.animate_with(fx.interval) { fx.step }
end
