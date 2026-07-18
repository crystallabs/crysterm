require "./spec_helper"

include Crysterm

# Regression specs for the BUGS5 style-engine fixes (see BUGS5.md):
#
#  1. `parse_animation` treated the FIRST shorthand token as the @keyframes name,
#     so `animation: 2s linear infinite spin` set name = "2s" and the animation
#     silently never played. The name is now the token that is not a <time>, not a
#     keyword/easing, and not a bare count (preferring the last such token).
#  2. `parse_transition` read tokens positionally (dur = toks[1], easing = toks[2]),
#     mis-reading valid orderings like `opacity ease-out 0.3s` / `color ease-in`.
#     Tokens are now classified by kind; unitless numbers are not durations.
#  3. `parse_box_shadow` captured a bare fractional offset in 0..1 as the opacity
#     (`0.0 4px 8px black` → invisible). A number in the leading geometry run is
#     now treated as an offset, never opacity.
#  4. `Shadow.from` lacked an `Int` arm (unlike `Border`/`Padding`/`Margin`), so
#     `Style.new(shadow: 2)` failed to compile.

private def anim(value : String)
  s = Style.new
  Crysterm::CSS::Properties.apply(s, "animation", value)
  s.animation
end

private def trans(value : String)
  s = Style.new
  Crysterm::CSS::Properties.apply(s, "transition", value)
  s.transitions
end

private def box_shadow(value : String)
  s = Style.new
  Crysterm::CSS::Properties.apply(s, "box-shadow", value)
  s.shadow
end

describe "BUGS5 parse_animation name detection (fix #1)" do
  it "finds the name when the duration comes first" do
    spec = anim("2s spin").not_nil!
    spec.name.should eq "spin"
    spec.duration.should eq 2.seconds
  end

  it "finds the name after duration + easing + count keywords" do
    spec = anim("3s ease-out infinite slidein").not_nil!
    spec.name.should eq "slidein"
    spec.duration.should eq 3.seconds
    spec.easing.should eq Easing::OutQuad
    spec.iterations.should be_nil # infinite
  end

  it "still parses a leading-name shorthand (no regression)" do
    spec = anim("pulse 2s ease-in-out infinite alternate").not_nil!
    spec.name.should eq "pulse"
    spec.duration.should eq 2.seconds
    spec.iterations.should be_nil
    spec.alternate.should be_true
  end

  it "keeps a bare integer as the iteration count, not the name" do
    spec = anim("go 0.15s linear 1").not_nil!
    spec.name.should eq "go"
    spec.iterations.should eq 1
  end

  it "prefers the last non-keyword token as the name" do
    anim("2s linear infinite spin").not_nil!.name.should eq "spin"
  end
end

describe "BUGS5 parse_transition kind-based classification (fix #2)" do
  it "reads the easing before the duration (`ease-out 0.3s`)" do
    t = trans("opacity ease-out 0.3s").not_nil!["opacity"]
    t[0].should eq 0.3.seconds
    t[1].should eq Easing::OutQuad
  end

  it "reads an easing with no duration (`color ease-in`)" do
    t = trans("color ease-in").not_nil!["color"]
    t[0].should eq 0.3.seconds # default duration
    t[1].should eq Easing::InQuad
  end

  it "still reads the canonical `<prop> <dur> <easing>` order" do
    t = trans("opacity 0.3s ease-in-out").not_nil!["opacity"]
    t[0].should eq 0.3.seconds
    t[1].should eq Easing::InOutSine
  end

  it "does not treat a unitless number as a duration" do
    t = trans("opacity 300").not_nil!["opacity"]
    t[0].should eq 0.3.seconds # 300 rejected → default, not 300.seconds
  end
end

describe "BUGS5 parse_box_shadow offset-vs-opacity (fix #3)" do
  it "does not read a leading `0.0` offset as an (invisible) opacity" do
    sh = box_shadow("0.0 4px 8px black")
    sh.any?.should be_true   # shadow enabled...
    sh.opacity.should eq 0.5 # ...at the default opacity, not 0.0
  end

  it "does not read fractional offsets as the opacity" do
    box_shadow("0.5 0.5 black").opacity.should eq 0.5 # default, not 0.5-from-offset
  end

  it "still honors a real opacity placed after the color" do
    box_shadow("2px 2px black 0.3").opacity.should eq 0.3
  end

  it "keeps a unit'd fractional offset out of the opacity slot" do
    box_shadow("0.5px 0.5px black").opacity.should eq 0.5 # unchanged default
  end
end

describe "BUGS5 Shadow.from integer arm (fix #4)" do
  it "coerces a bare integer to an all-sides shadow" do
    sh = Shadow.from(2)
    sh.left.should eq 2
    sh.top.should eq 2
    sh.right.should eq 2
    sh.bottom.should eq 2
  end

  it "compiles and works through `Style.new(shadow:)`" do
    Style.new(shadow: 2).shadow.right.should eq 2
  end
end
