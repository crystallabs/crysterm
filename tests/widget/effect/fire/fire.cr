# Example: Crysterm::Widget::Effect::Fire
#
# Minimal, self-contained example of a single Fire.
# Run it:     crystal run tests/widget/effect/fire/fire.cr
require "../../example"

alias CT = Crysterm
alias CW = CT::Widgets

Crysterm::WidgetExample.run "Fire" do |window|
  fx = CW::EffectFire.new parent: window, top: 0, left: 0, width: "100%", height: "100%"
  Crysterm::WidgetExample.animate_with(fx.interval) { fx.step }
end
