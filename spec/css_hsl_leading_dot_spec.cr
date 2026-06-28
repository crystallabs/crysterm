require "./spec_helper"

include Crysterm

# Focused spec for `Crysterm::CSS::ColorValue.resolve` with a CSS *leading-dot*
# decimal in an `hsl()` argument (`.5turn`, `.25turn`, ...).
#
# CSS lets a number omit the integer part (`.5` == `0.5`, per the `<number>`
# grammar — the same form `Length::NUM` already accepts). The color number
# regexes required at least one leading digit, so `.5turn` matched only the
# `5turn` *after* the dot: it resolved as `5turn` (1800° ≡ 0°, red) instead of
# `0.5turn` (180°, cyan). The regexes now accept the leading-dot form, so an
# integer-less angle reads as the fraction it is.
describe "Crysterm::CSS::ColorValue hsl() leading-dot angle" do
  cyan = (0 << 16) | (255 << 8) | 255 # hsl(180, 100%, 50%)

  it "reads a leading-dot `turn` (.5turn == 0.5turn == 180deg, cyan)" do
    Crysterm::CSS::ColorValue.resolve("hsl(.5turn, 100%, 50%)", nil).should eq cyan
  end

  it "agrees with the explicit-zero form (.5turn == 0.5turn)" do
    Crysterm::CSS::ColorValue.resolve("hsl(.5turn, 100%, 50%)", nil)
      .should eq Crysterm::CSS::ColorValue.resolve("hsl(0.5turn, 100%, 50%)", nil)
  end
end
