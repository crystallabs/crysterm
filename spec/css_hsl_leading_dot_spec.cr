require "./spec_helper"

include Crysterm

# `Crysterm::CSS::ColorValue.resolve` with a CSS leading-dot decimal in an
# `hsl()` argument (`.5turn`, `.25turn`, ...).
#
# CSS lets a number omit the integer part (`.5` == `0.5`), so the color number
# regexes must accept the leading-dot form — requiring a leading digit reads
# `.5turn` as `5turn`, resolving 1800° ≡ 0° (red) instead of 180° (cyan).
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
