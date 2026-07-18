require "./spec_helper"

include Crysterm
include Crysterm::Helpers

# Regression spec for the BUGS8 GaugeList fix: the label column was sized and
# filled by codepoint count (`String#size`), so a wide (CJK) label — 1 codepoint
# but 2 terminal columns — made the emitted row wider than the interior, shoving
# the bar/percentage past the border and wrapping the row. The fix measures and
# fills the label by display width (under `full_unicode?`, as `pad_cell` does).

private def uni_screen(w = 30, h = 8)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, full_unicode: true, force_unicode: true)
end

describe "BUGS8 GaugeList sizes the label column by display width" do
  it "keeps a wide-glyph label row within the interior width (no overflow)" do
    s = uni_screen
    s.full_unicode_effective?.should be_true

    gl = Crysterm::Widget::GaugeList.new parent: s, top: 0, left: 0, width: 20, height: 4
    gl.add_item "日本", 50 # 2 codepoints, 4 display columns
    s._render

    cols = gl.awidth.not_nil! - gl.ihorizontal
    line = clean_tags(gl.content) # single gauge → single content line
    # The row must be exactly the interior width. Pre-fix the label counted as 2
    # columns instead of 4, so the row came out 2 columns too wide (→ wrap).
    Crysterm::Unicode.display_width(line).should eq cols
  end

  it "still fits an ascii label exactly (no regression)" do
    s = uni_screen
    gl = Crysterm::Widget::GaugeList.new parent: s, top: 0, left: 0, width: 20, height: 4
    gl.add_item "cpu", 64
    s._render
    cols = gl.awidth.not_nil! - gl.ihorizontal
    Crysterm::Unicode.display_width(clean_tags(gl.content)).should eq cols
  end
end
