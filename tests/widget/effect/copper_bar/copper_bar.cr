# Example: Crysterm::Widget::Effect::CopperBar
#
# Minimal, self-contained example of a single CopperBar.
# Run it:     crystal run examples/widget/effect/copper_bar/copper_bar.cr
# Maintained by tools/manage-examples.cr
require "../../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "CopperBar" do |window|
  hues = [0, 70, 150, 230]
  bar_h = 4
  bars = [] of EffectCopperBar
  hues.each_with_index do |hue, b|
    bar_h.times do |r|
      edge = (r * 2 - (bar_h - 1)).abs / (bar_h - 1).to_f # 0 centre .. 1 edge
      bars << EffectCopperBar.new \
        parent: window, left: 0, width: "100%", height: 1,
        top: 2 + b * (bar_h + 1) + r, hue_offset: hue, brightness: 1.0 - 0.75 * edge
    end
  end
  Crysterm::WidgetExample.animate_with(bars.first.interval) { bars.each(&.step) }
end
