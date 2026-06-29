require "./spec_helper"

include Crysterm

# Phase 2a: the width-measurement hook `Widget#str_width`.
#
# This pure spec covers the legacy path (no screen attached -> `full_unicode?`
# is false), which must stay codepoint-counted, and confirms SGR sequences are
# stripped before measuring. The full-unicode (column-width) path needs an
# attached, Unicode-capable screen and is exercised by
# `test/`-style run verification rather than here, since constructing real
# `Window`s in the spec process interferes with the spec runner's teardown.
describe "Widget#str_width (legacy / unattached)" do
  it "counts codepoints when full_unicode is not active" do
    b = Widget::Box.new
    b.full_unicode?.should be_false
    b.str_width("abc").should eq 3
    b.str_width("中").should eq 1   # one codepoint in legacy mode
    b.str_width("a中b").should eq 3 # three codepoints
  end

  it "strips SGR sequences before measuring" do
    b = Widget::Box.new
    b.str_width("\e[31mX\e[0m").should eq 1
    b.str_width("\e[1;31mabc\e[0m").should eq 3
  end

  it "tail_within keeps the widest grapheme suffix that fits the column budget" do
    b = Widget::Box.new
    b.tail_within("ab中de", 10).should eq "ab中de" # all fits (width 6)
    b.tail_within("ab中de", 4).should eq "中de"    # 2 + 1 + 1
    b.tail_within("ab中de", 3).should eq "de"     # 中 (2 cols) won't fit in the last column
    b.tail_within("ab中de", 0).should eq ""
  end

  it "wrap_cut_index cuts at the codepoint reaching the column budget" do
    b = Widget::Box.new
    b.wrap_cut_index("abcdef", 3).should eq 3
    b.wrap_cut_index("abc", 5).should eq 3 # whole line fits
  end

  it "wrap_cut_index does not count SGR sequences toward width" do
    b = Widget::Box.new
    # 'a','b' are the only visible columns; cut after 'b' (the SGR run is kept).
    b.wrap_cut_index("a\e[31mbc", 2).should eq 7
  end

  it "chop_grapheme removes the last whole grapheme cluster" do
    b = Widget::Box.new
    b.chop_grapheme("abc").should eq "ab"
    b.chop_grapheme("a中").should eq "a"         # a wide cluster comes off as one
    b.chop_grapheme("xe\u{0301}").should eq "x" # base+combining removed as one unit
    b.chop_grapheme("e\u{0301}").should eq ""
    b.chop_grapheme("").should eq ""
  end
end
