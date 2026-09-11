# Example: Crysterm::Widget::Effect::Matrix
#
# Minimal, self-contained example of a single Matrix.
# Run it:     crystal run tests/widget/effect/matrix/matrix.cr
require "../../example"

alias CT = Crysterm
alias CW = CT::Widgets

Crysterm::WidgetExample.run "Matrix" do |window|
  rain = CW::EffectMatrix.new parent: window, top: 0, left: 0, width: "100%", height: "100%"
  Crysterm::WidgetExample.animate_with(rain.interval) { rain.step }
end
