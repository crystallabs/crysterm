require "./spec_helper"

include Crysterm

# A function color (`rgb()`/`hsl()`) carries internal spaces/commas, so the
# `background`/`tint` shorthand must tokenize with `Properties.split_top_level`,
# which keeps parenthesized argument lists intact — a plain `String#split`
# shreds `rgb(30, 30, 46)` and silently drops the color.
describe "CSS background/tint shorthand with a function color" do
  it "pulls an rgb() color out of the `background` shorthand" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "background", "rgb(30, 30, 46)")
    s.bg.should eq 0x1e1e2e
  end

  it "pulls an hsl() color out of the `background` shorthand" do
    s = Style.new
    # hsl(0, 100%, 50%) == pure red
    Crysterm::CSS::Properties.apply(s, "background", "hsl(0, 100%, 50%)")
    s.bg.should eq 0xff0000
  end

  it "still finds the color in a mixed shorthand alongside a url()" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "background", "rgb(30, 30, 46) url(x.png) no-repeat")
    s.bg.should eq 0x1e1e2e
    s.background_image.should eq "x.png"
  end

  it "keeps the existing single-token shorthand behavior" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "background", "blue url(x.png) no-repeat")
    s.bg.should eq Colors.convert("blue")
    s.background_image.should eq "x.png"
  end

  it "pulls an rgb() color out of the `tint` shorthand (with strength)" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "tint", "rgb(255, 0, 0) 0.3")
    s.tint.should eq 0xff0000
    s.tint_alpha.should eq 0.3
  end
end
