# Example: Crysterm::Widget::Effect::Spray
#
# Minimal, self-contained example of a single Spray.
# Run it:     crystal run tests/widget/effect/spray/spray.cr
require "../../example"

alias CT = Crysterm
alias CW = CT::Widgets

Crysterm::WidgetExample.run "Spray" do |window|
  fx = CW::EffectSpray.new parent: window, top: 0, left: 0, width: "100%", height: "100%"
  Crysterm::WidgetExample.animate_with(fx.interval) { fx.step }
end
