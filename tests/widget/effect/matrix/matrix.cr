# Example: Crysterm::Widget::Effect::Matrix
#
# Minimal, self-contained example of a single Matrix.
# Run it:     crystal run examples/widget/effect/matrix/matrix.cr
# Maintained by tools/manage-examples.cr
require "../../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "Matrix" do |window|
  rain = EffectMatrix.new parent: window, top: 0, left: 0, width: "100%", height: "100%"
  Crysterm::WidgetExample.animate_with(rain.interval) { rain.step }
end
