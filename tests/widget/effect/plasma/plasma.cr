# Example: Crysterm::Widget::Effect::Plasma
#
# Minimal, self-contained example of a single Plasma.
# Run it:     crystal run tests/widget/effect/plasma/plasma.cr
require "../../example"

alias CT = Crysterm
alias CW = CT::Widgets

Crysterm::WidgetExample.run "Plasma" do |window|
  fx = CW::EffectPlasma.new parent: window, top: 0, left: 0, width: "100%", height: "100%"
  Crysterm::WidgetExample.animate_with(fx.interval) { fx.step }
end
