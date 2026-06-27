require "./spec_helper"

include Crysterm

# Focused spec for `Crysterm::CSS::ColorValue.gradient_color`.
#
# A terminal cell can't paint a real gradient, so a CSS/Qt gradient is collapsed
# to the channel-wise average of its stop colors. The stop scanner used to match
# only `#hex`/`rgb()` stops, so a *plain CSS* gradient with named (or `hsl()`)
# stops — `linear-gradient(to right, red, blue)` — harvested no color and the
# whole declaration silently fell back to the terminal default. Named colors,
# `hsl()`, and the gradient's non-color keywords (`to`/`right`/...) are now all
# tokenized; only the real colors contribute to the average.
private def avg(*colors : Int32) : Int32
  r = colors.sum { |c| (c >> 16) & 0xff } // colors.size
  g = colors.sum { |c| (c >> 8) & 0xff } // colors.size
  b = colors.sum { |c| c & 0xff } // colors.size
  (r << 16) | (g << 8) | b
end

describe "Crysterm::CSS::ColorValue.gradient_color" do
  it "averages named-color stops in a plain CSS gradient" do
    red = Colors.convert_cached("red")
    blue = Colors.convert_cached("blue")
    Crysterm::CSS::ColorValue.gradient_color("linear-gradient(to right, red, blue)")
      .should eq avg(red, blue)
  end

  it "ignores direction/shape keywords, not just colors" do
    # `to`, `right`, `circle`, `at`, `center` must not skew the average.
    red = Colors.convert_cached("red")
    Crysterm::CSS::ColorValue.gradient_color("radial-gradient(circle at center, red, red)")
      .should eq red
  end

  it "averages hsl() stops" do
    # hsl(0,100%,50%) == red, hsl(240,100%,50%) == blue.
    r = 0xff0000
    b = 0x0000ff
    Crysterm::CSS::ColorValue.gradient_color("linear-gradient(hsl(0, 100%, 50%), hsl(240, 100%, 50%))")
      .should eq avg(r, b)
  end

  it "still averages hex stops in a Qt qlineargradient (unchanged)" do
    css = "qlineargradient(x1: 0, y1: 0, x2: 0, y2: 1, stop: 0 #2a79a3, stop: 1 #2a79a3)"
    Crysterm::CSS::ColorValue.gradient_color(css).should eq 0x2a79a3
  end

  it "returns nil for a non-gradient value" do
    Crysterm::CSS::ColorValue.gradient_color("#ff0000").should be_nil
  end
end
