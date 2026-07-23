require "./spec_helper"

include Crysterm

# Regression specs for BUGS18 B18-29, B18-30, B18-31, B18-37 —
# `Crysterm::CSS::Properties.apply` / `SidedGeometry#any?` bugs.
describe "BUGS18 CSS parsing fixes" do
  # B18-29: `with_color` (shared by `color`, `background-color`,
  # `alternate-background-color`, `gridline-color`, and the 1-token
  # `border-color` branch) used to let an unknown color name (a typo like
  # "bleu") through to the setter, which stores `Colors.convert_cached`'s -1
  # unknown-name sentinel and clobbers whatever color was previously set. CSS
  # requires the invalid declaration to be dropped instead.
  describe "unknown color name (with_color)" do
    it "drops an unknown `color` name, keeping the prior color" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "color", "red")
      Crysterm::CSS::Properties.apply(s, "color", "bleu")
      s.fg.should eq Colors.convert_cached("red")
    end

    it "drops an unknown `background-color` name, keeping the prior color" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "background-color", "#00ff00")
      Crysterm::CSS::Properties.apply(s, "background-color", "gren")
      s.bg.should eq Colors.convert_cached("#00ff00")
    end

    it "drops an unknown 1-token `border-color`, keeping the prior whole-border color and per-side override" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "border-color", "#0000ff")
      Crysterm::CSS::Properties.apply(s, "border-top-color", "red")
      Crysterm::CSS::Properties.apply(s, "border-color", "bleu")
      s.border.fg.should eq Colors.convert_cached("#0000ff")
      s.border.top_fg.should eq Colors.convert_cached("red")
    end

    it "still applies a valid single-token border-color and clears per-side overrides" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "border-top-color", "red")
      Crysterm::CSS::Properties.apply(s, "border-color", "green")
      s.border.fg.should eq Colors.convert_cached("green")
      s.border.@top_fg.should be_nil
    end

    it "keeps a genuine transparent (-1 Int32) distinct from the unknown-name drop case" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "color", "red")
      Crysterm::CSS::Properties.apply(s, "color", "transparent")
      s.fg.should eq(-1)
    end

    it "still resets on the genuine-unset keyword `inherit`" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "color", "red")
      Crysterm::CSS::Properties.apply(s, "color", "inherit")
      s.fg.should be_nil
    end
  end

  # B18-30: standard `animation` shorthand keywords (fill-mode/play-state/
  # direction) and a fractional iteration count used to fall through to the
  # keyframes-name fallback and hijack the name (last-wins), so the animation
  # silently never resolved any @keyframes stops.
  describe "animation shorthand keyword/fractional-count hijack" do
    it "does not let `forwards` (fill-mode) hijack the keyframes name" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "animation", "fadein 1s ease-out forwards")
      spec = s.animation.not_nil!
      spec.name.should eq "fadein"
      spec.duration.should eq 1.seconds
    end

    it "does not let `both` (fill-mode) hijack the keyframes name" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "animation", "pulse 2s ease-in-out infinite both")
      spec = s.animation.not_nil!
      spec.name.should eq "pulse"
      spec.iterations.should be_nil # infinite
    end

    it "maps `alternate-reverse` onto the `alternate` flag without hijacking the name" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "animation", "spin 2s linear alternate-reverse")
      spec = s.animation.not_nil!
      spec.name.should eq "spin"
      spec.alternate.should be_true
    end

    it "does not let `paused` (play-state) hijack the keyframes name" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "animation", "wiggle 1s paused")
      spec = s.animation.not_nil!
      spec.name.should eq "wiggle"
    end

    it "does not let `reverse` (direction) hijack the keyframes name" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "animation", "flip 1s reverse")
      spec = s.animation.not_nil!
      spec.name.should eq "flip"
    end

    it "rounds a fractional iteration count up instead of letting it hijack the name" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "animation", "bounce 1s linear 1.5")
      spec = s.animation.not_nil!
      spec.name.should eq "bounce"
      spec.iterations.should eq 2
    end

    it "drops the whole declaration on a non-finite fractional token (inf)" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "animation", "foo 1s inf")
      s.animation.should be_nil
    end

    it "drops the whole declaration on a non-finite fractional token (nan)" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "animation", "foo 1s nan")
      s.animation.should be_nil
    end
  end

  # B18-31: `SidedGeometry#any?` summed the four sides, so a legitimate
  # negative margin whose sides sum to <= 0 was misreported as "no margin",
  # silently dropping it at every margin consumer gated on `any?`.
  describe "SidedGeometry#any? with negative sides" do
    it "is true for a lone negative side (sum <= 0)" do
      Margin.new(0, -1, 0, 0).any?.should be_true
    end

    it "is true for sides that cancel to zero" do
      Margin.new(-2, 0, 2, 0).any?.should be_true
    end

    it "is false when every side is genuinely zero" do
      Margin.new(0, 0, 0, 0).any?.should be_false
    end

    it "is true when the sum happens to be positive (control case)" do
      Margin.new(-1, 0, 3, 0).any?.should be_true
    end

    it "reflects a negative margin-top applied through the CSS cascade" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "margin-top", "-1")
      s.margin.top.should eq(-1)
      s.margin.any?.should be_true
    end
  end

  # B18-37: `box-shadow` tokenized with a plain `String#split`, shredding a
  # space-separated color function (`rgb(0.2 0.4 0.6)`) into fragments; a
  # bare fractional fragment ("0.4") was then misread as the opacity shorthand
  # instead of the intended default.
  describe "box-shadow color-function tokenization" do
    it "does not misread a space-separated rgb() channel as opacity" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "box-shadow", "2px 2px rgb(0.2 0.4 0.6)")
      s.shadow.opacity.should eq 0.5 # default, not 0.4
    end

    it "does not misread a space-separated color(srgb ...) channel as opacity" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "box-shadow", "0 4px 8px color(srgb 0.2 0.4 0.6)")
      s.shadow.opacity.should eq 0.5 # default, not 0.2
    end

    it "still reads a bare fractional opacity outside any function" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "box-shadow", "2px 2px black 0.3")
      s.shadow.opacity.should eq 0.3
    end

    it "still reads the legacy comma rgba() form correctly" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "box-shadow", "0 4px 8px rgba(0,0,0,0.5)")
      s.shadow.opacity.should eq 0.5
    end
  end
end
