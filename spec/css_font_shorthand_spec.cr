require "./spec_helper"

include Crysterm

# Focused specs for the CSS `font` shorthand parser
# (`Crysterm::CSS::Properties.apply`). The interesting case is the *weight*:
# the shorthand must recognize the same numeric/relative CSS weights the
# `font-weight` longhand does (via `font_weight_bold`) — `font: 700 14px serif`
# is bold, not only the literal `bold` keyword. It used to test for the bare
# string "bold" alone, silently rendering a clearly-bold shorthand non-bold.
describe "CSS font shorthand" do
  it "is bold for the literal `bold` keyword" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "font", "bold 14px serif")
    s.bold?.should be_true
  end

  it "is bold for a numeric weight over 500 (`700`)" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "font", "700 14px serif")
    s.bold?.should be_true
  end

  it "is bold for the relative `bolder` keyword" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "font", "bolder 14px serif")
    s.bold?.should be_true
  end

  it "is not bold for a numeric weight at/under 500 (`400`)" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "font", "400 14px serif")
    s.bold?.should be_false
  end

  it "matches the `font-weight` longhand for a numeric weight" do
    short = Style.new
    Crysterm::CSS::Properties.apply(short, "font", "600 14px serif")
    long = Style.new
    Crysterm::CSS::Properties.apply(long, "font-weight", "600")
    short.bold?.should eq long.bold?
    short.bold?.should be_true
  end

  it "resets bold (shorthand semantics) when no weight word is present" do
    s = Style.new
    s.bold = true
    Crysterm::CSS::Properties.apply(s, "font", "14px serif")
    s.bold?.should be_false
  end

  it "is italic for `italic` and for the slanted `oblique`" do
    a = Style.new
    Crysterm::CSS::Properties.apply(a, "font", "italic 14px serif")
    a.italic?.should be_true
    b = Style.new
    Crysterm::CSS::Properties.apply(b, "font", "oblique 14px serif")
    b.italic?.should be_true
  end

  it "is bold+italic together (`bold italic`)" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "font", "bold italic 14px serif")
    s.bold?.should be_true
    s.italic?.should be_true
  end

  # The `font-style` *longhand* must recognize the same slant keywords the
  # shorthand does. `oblique` slants like `italic`; the longhand used to accept
  # only `italic`/`normal`, so `font-style: oblique` silently rendered upright —
  # the mirror of the `font-weight` longhand/shorthand fix above.
  it "is italic for the `font-style: oblique` longhand (matches the shorthand)" do
    long = Style.new
    Crysterm::CSS::Properties.apply(long, "font-style", "oblique")
    long.italic?.should be_true

    short = Style.new
    Crysterm::CSS::Properties.apply(short, "font", "oblique 14px serif")
    long.italic?.should eq short.italic?
  end

  it "clears italic for `font-style: normal`" do
    s = Style.new
    s.italic = true
    Crysterm::CSS::Properties.apply(s, "font-style", "normal")
    s.italic?.should be_false
  end
end
