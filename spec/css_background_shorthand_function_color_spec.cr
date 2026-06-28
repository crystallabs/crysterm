require "./spec_helper"

include Crysterm

# A function color (`rgb()`/`hsl()`) carries internal spaces/commas. The
# `background` (and `tint`) *shorthand* used to tokenize its value with a plain
# `String#split`, which shredded `rgb(30, 30, 46)` into `["rgb(30,", "30,",
# "46)"]` — none of which parses — so the color was silently dropped, even
# though the `background-color` longhand (resolving the whole value at once)
# handled it fine. `Properties.split_top_level` now keeps a parenthesized
# argument list intact, so a function color survives the shorthand.
describe "CSS background/tint shorthand with a function color" do
  it "pulls an rgb() color out of the `background` shorthand" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "background", "rgb(30, 30, 46)")
    s.bg.should eq 0x1e1e2e
  end

  it "pulls an hsl() color out of the `background` shorthand" do
    s = Style.new
    # hsl(0, 100%, 50%) == pure red.
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
