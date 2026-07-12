require "./spec_helper"

include Crysterm

# Regression specs for BUGS15 CSS-property parser fixes
# (`Crysterm::CSS::Properties.apply`).
#
#  #8  `tab-size` must drop a negative value (an invalid declaration) — a
#      negative tab width later raises `ArgumentError("Negative argument")` in
#      `tab_char * tab_size` on the render fiber.
#  #40 `background-size: 100%  100%` (any inter-token whitespace) must still be a
#      full Stretch, not silently degrade to Cover.
#  #41 `border-<side>-width` with a blank/unparseable value must drop the
#      declaration (leave the cascaded width), not hard-reset the side to 0.
describe "BUGS15 CSS property parser fixes" do
  describe "#8 tab-size negative value" do
    it "drops a negative tab-size, keeping the previously-set value" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "tab-size", "8")
      Crysterm::CSS::Properties.apply(s, "tab-size", "-2")
      s.tab_size.should eq 8
    end

    it "keeps the default tab-size when a negative value is the only declaration" do
      s = Style.new
      default = s.tab_size
      Crysterm::CSS::Properties.apply(s, "tab-size", "-2")
      s.tab_size.should eq default
      # And the stored width is non-negative, so the render path never raises.
      (s.tab_char * s.tab_size).should_not be_nil
    end

    it "still accepts a valid non-negative tab-size" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "tab-size", "0")
      s.tab_size.should eq 0
      Crysterm::CSS::Properties.apply(s, "tab-size", "2")
      s.tab_size.should eq 2
    end
  end

  describe "#40 background-size whitespace" do
    it "treats extra whitespace between the 100% tokens as a full Stretch" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "background-size", "100%  100%")
      s.background_size.should eq Style::BackgroundSize::Stretch
    end

    it "treats a tab between the 100% tokens as a full Stretch" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "background-size", "100%\t100%")
      s.background_size.should eq Style::BackgroundSize::Stretch
    end

    it "still maps the canonical spellings and unknown input" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "background-size", "100% 100%")
      s.background_size.should eq Style::BackgroundSize::Stretch
      Crysterm::CSS::Properties.apply(s, "background-size", "contain")
      s.background_size.should eq Style::BackgroundSize::Contain
      Crysterm::CSS::Properties.apply(s, "background-size", "banana")
      s.background_size.should eq Style::BackgroundSize::Cover
    end
  end

  describe "#41 border-<side>-width blank/unparseable value" do
    it "drops a blank border-top-width instead of resetting the side to 0" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "border", "solid")
      before = s.border.top
      before.should be > 0
      # An undefined `var()` collapses to "": CSS drops the declaration.
      Crysterm::CSS::Properties.apply(s, "border-top-width", "")
      s.border.top.should eq before
    end

    it "drops an unparseable border-left-width, keeping the cascaded width" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "border", "solid")
      before = s.border.left
      Crysterm::CSS::Properties.apply(s, "border-left-width", "thinn")
      s.border.left.should eq before
    end

    it "still applies a genuine border width (including 0)" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "border", "solid")
      Crysterm::CSS::Properties.apply(s, "border-bottom-width", "3")
      s.border.bottom.should eq 3
      Crysterm::CSS::Properties.apply(s, "border-right-width", "0")
      s.border.right.should eq 0
    end
  end

  describe "#47 animation-iteration-count parse" do
    it "accepts a zero iteration count" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "animation", "hide 1s 0")
      spec = s.animation.not_nil!
      spec.iterations.should eq 0
    end

    it "drops the whole declaration for a negative iteration count" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "animation", "hide 1s -1")
      s.animation.should be_nil
    end
  end
end
