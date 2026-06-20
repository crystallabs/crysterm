require "./spec_helper"

include Crysterm

# Phase 1: the cell model — grapheme overlay + continuation cells on
# `Screen::Row` / `Screen::Cell`. Exercised directly on a `Row` (no `Screen`).
private def row1
  r = Crysterm::Screen::Row.new
  r.push # one default cell
  r
end

describe Crysterm::Screen::Cell do
  it "stores a single-codepoint grapheme inline (no overlay)" do
    r = row1
    c = r[0]
    c.grapheme = "中"
    c.char.should eq '中'
    c.grapheme.should eq "中"
    c.grapheme_overlay.should be_nil
    c.width.should eq 2
    c.continuation?.should be_false
    # read back through a fresh handle (mutations go to the row)
    r[0].grapheme.should eq "中"
  end

  it "stores a multi-codepoint cluster in the overlay, keeping the base char" do
    r = row1
    c = r[0]
    c.grapheme = "e\u{0301}" # é decomposed (2 codepoints, 1 column)
    c.char.should eq 'e'
    c.grapheme.should eq "e\u{0301}"
    c.grapheme_overlay.should eq "e\u{0301}"
    c.width.should eq 1
  end

  it "marks and clears continuation cells" do
    r = row1
    c = r[0]
    c.continuation!
    c.continuation?.should be_true
    c.grapheme.should eq ""
    c.width.should eq 0
    c.char = 'x' # clears the continuation marker
    c.continuation?.should be_false
    c.grapheme.should eq "x"
  end

  it "char= drops a previous cluster overlay" do
    r = row1
    c = r[0]
    c.grapheme = "e\u{0301}"
    c.grapheme_overlay.should_not be_nil
    c.char = 'z'
    c.grapheme_overlay.should be_nil
    c.grapheme.should eq "z"
  end

  it "compares cells by attr + full grapheme" do
    a = row1[0]
    b = row1[0]
    a.grapheme = "e\u{0301}"
    b.grapheme = "e\u{0301}"
    (a == b).should be_true

    b.grapheme = "e"         # base only -> single codepoint, no overlay
    (a == b).should be_false # cluster vs single, same base
  end

  it "a cluster cell is never equal to a single-char tuple" do
    c = row1[0]
    c.grapheme = "e\u{0301}"
    (c == {c.attr, 'e'}).should be_false

    plain = row1[0]
    plain.char = 'e'
    (plain == {plain.attr, 'e'}).should be_true
  end

  it "pop drops the popped cell's overlay" do
    r = Crysterm::Screen::Row.new
    r.push
    r.push
    r[1].grapheme = "e\u{0301}"
    r.grapheme_at?(1).should_not be_nil
    r.pop
    r.grapheme_at?(1).should be_nil
  end
end
