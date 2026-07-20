# Example: Crysterm::Widget::Effect::SineScroller
#
# Minimal, self-contained example of a single SineScroller.
# Run it:     crystal run examples/widget/effect/sine_scroller/sine_scroller.cr
# Maintained by tools/manage-examples.cr
require "../../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "SineScroller" do |window|
  fx = EffectSineScroller.new parent: window, top: "center", left: 0, width: "100%", height: 11,
    text: "CRYSTERM * SINE SCROLLER * "
  Crysterm::WidgetExample.animate_with(fx.interval) { fx.step }
end
