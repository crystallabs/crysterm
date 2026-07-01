require "./spec_helper"

include Crysterm

# Regression specs for `Colors.convert_cached` (the public, cached entry point
# through which every widget/CSS color string is resolved) handling the two
# hex-with-alpha forms.
#
# `TermColors#convert` only understands `#rgb` / `#rrggbb`; the 4-digit
# (`#rgba`) and 8-digit (`#rrggbbaa`) forms fell through to the `-1`
# ("terminal default") sentinel. `Colors` now strips the alpha nibble/byte
# (`strip_hex_alpha`) before delegating, so an `#rgba`/`#rrggbbaa` resolves to
# the same RGB as its alpha-free counterpart.
describe "Colors.convert_cached (hex alpha forms)" do
  it "resolves #rgba the same as #rgb (alpha ignored)" do
    Colors.convert_cached("#f00a").should eq Colors.convert_cached("#f00")
    Colors.convert_cached("#f00a").should eq Colors.convert_cached("#ff0000")
    Colors.convert_cached("#f00a").should eq 0xff0000
  end

  it "resolves #rrggbbaa the same as #rrggbb (alpha ignored)" do
    Colors.convert_cached("#12345678").should eq Colors.convert_cached("#123456")
    Colors.convert_cached("#12345678").should eq 0x123456
  end

  it "ignores the alpha regardless of its value" do
    # Different alpha nibbles/bytes must not change the resolved RGB.
    Colors.convert_cached("#f000").should eq Colors.convert_cached("#f00f")
    Colors.convert_cached("#12345600").should eq Colors.convert_cached("#123456ff")
  end

  # Regression guards: the pre-existing forms must resolve exactly as before.
  it "still resolves plain #rrggbb" do
    Colors.convert_cached("#123456").should eq 0x123456
  end

  it "still resolves shorthand #rgb" do
    Colors.convert_cached("#abc").should eq 0xaabbcc
  end

  it "still resolves named colors to a concrete (non-default) RGB" do
    # The named palette's "red" is the xterm red (0xcd0000), not pure 0xff0000;
    # the point is it resolves to a real color rather than the -1 default.
    Colors.convert_cached("red").should eq 0xcd0000
    Colors.convert_cached("red").should_not eq -1
  end

  it "yields the -1 default for clearly-malformed hex without crashing" do
    Colors.convert_cached("bogus###").should eq -1
    # 5/9-char hex that isn't valid hex still falls through to the default.
    Colors.convert_cached("#gggg").should eq -1
  end
end

# The same values flowing through a CSS `color` / `background-color`
# declaration onto a widget's `Style` (see `spec/css_color_invalid_spec.cr`).
describe "CSS color (hex alpha forms)" do
  it "applies an #rgba `color` as the alpha-free foreground" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "color", "#f00a")
    s.fg.should eq 0xff0000
  end

  it "applies an #rrggbbaa `background-color` as the alpha-free background" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "background-color", "#12345678")
    s.bg.should eq 0x123456
  end
end
