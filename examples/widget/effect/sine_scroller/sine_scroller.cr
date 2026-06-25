# Example: Crysterm::Widget::Effect::SineScroller
#
# Minimal, self-contained example of a single SineScroller.
# Run it:     crystal run examples/widget/effect/sine_scroller/sine_scroller.cr
# Maintained by tools/manage-examples.cr
require "../../example"

Crysterm::WidgetExample.run "SineScroller" do |screen|
  fx = Crysterm::Widget::Effect::SineScroller.new parent: screen, top: "center", left: 0, width: "100%", height: 11,
    text: "CRYSTERM * SINE SCROLLER * "
  Crysterm::WidgetExample.animate_with(fx.interval) { fx.step }
end
