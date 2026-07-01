require "./spec_helper"

include Crysterm

# Behavior lock for the pure helpers in `Widget::Graph::Scale` — the eighth-block
# arithmetic and label/row formatting shared by `Bar`/`StackedBar`/`Gauge`.
# All static, no widget or terminal needed.
describe Crysterm::Widget::Graph::Scale do
  describe ".eighths" do
    it "maps min/max to 0 and cells*8" do
      Crysterm::Widget::Graph::Scale.eighths(0.0, 0.0, 10.0, 3).should eq 0
      Crysterm::Widget::Graph::Scale.eighths(10.0, 0.0, 10.0, 3).should eq 24
      Crysterm::Widget::Graph::Scale.eighths(5.0, 0.0, 10.0, 4).should eq 16
    end

    it "clamps values outside [min, max]" do
      Crysterm::Widget::Graph::Scale.eighths(-5.0, 0.0, 10.0, 2).should eq 0
      Crysterm::Widget::Graph::Scale.eighths(99.0, 0.0, 10.0, 2).should eq 16
    end

    it "treats a non-positive range as 1.0 to avoid divide-by-zero" do
      # range <= 0 => range = 1.0, so (value-min) is taken over 1.0 then clamped.
      Crysterm::Widget::Graph::Scale.eighths(5.0, 5.0, 5.0, 2).should eq 0  # value==min => 0
      Crysterm::Widget::Graph::Scale.eighths(6.0, 5.0, 5.0, 2).should eq 16 # (1/1) clamps to 1 => full
    end

    it "rounds to the nearest eighth" do
      # 1/3 of a single 8-eighth cell = 2.66.. => rounds to 3.
      Crysterm::Widget::Graph::Scale.eighths(1.0, 0.0, 3.0, 1).should eq 3
    end
  end

  describe ".vglyph" do
    it "selects the partial glyph within the current cell" do
      # 10 filled eighths, 1 whole cell below => 10-8=2 => third glyph.
      Crysterm::Widget::Graph::Scale.vglyph(10, 1).should eq Crysterm::Widget::Graph::Scale::VERTICAL[2]
    end

    it "clamps below the cell to empty and above to full" do
      Crysterm::Widget::Graph::Scale.vglyph(0, 2).should eq ' '   # far below => empty
      Crysterm::Widget::Graph::Scale.vglyph(100, 0).should eq '█' # far above => full
    end
  end

  describe ".hglyph" do
    it "selects the partial glyph within the current cell" do
      Crysterm::Widget::Graph::Scale.hglyph(11, 1).should eq Crysterm::Widget::Graph::Scale::HORIZONTAL[3]
    end

    it "clamps to empty/full outside the cell" do
      Crysterm::Widget::Graph::Scale.hglyph(0, 3).should eq ' '
      Crysterm::Widget::Graph::Scale.hglyph(999, 0).should eq '█'
    end
  end

  describe ".center" do
    it "returns empty for non-positive width" do
      Crysterm::Widget::Graph::Scale.center("x", 0).should eq ""
      Crysterm::Widget::Graph::Scale.center("x", -3).should eq ""
    end

    it "truncates text at least as long as the field" do
      Crysterm::Widget::Graph::Scale.center("hello", 3).should eq "hel"
      Crysterm::Widget::Graph::Scale.center("abc", 3).should eq "abc"
    end

    it "centers with the extra space going to the right on odd padding" do
      # width 5, text 2 => pad 3, left = 1, right = 2.
      Crysterm::Widget::Graph::Scale.center("ab", 5).should eq " ab  "
      # width 4, text 2 => pad 2, left = 1, right = 1.
      Crysterm::Widget::Graph::Scale.center("ab", 4).should eq " ab "
    end
  end

  describe ".fmt" do
    it "drops the .0 from whole numbers" do
      Crysterm::Widget::Graph::Scale.fmt(5.0).should eq "5"
      Crysterm::Widget::Graph::Scale.fmt(-3.0).should eq "-3"
    end

    it "rounds non-integers to one decimal" do
      Crysterm::Widget::Graph::Scale.fmt(2.34).should eq "2.3"
      Crysterm::Widget::Graph::Scale.fmt(2.36).should eq "2.4"
    end
  end

  describe ".tagged_row" do
    it "coalesces same-colored runs into one tag pair" do
      s = String.build { |io| Crysterm::Widget::Graph::Scale.tagged_row(io, ['a', 'b', 'c'], ["red", "red", "red"]) }
      s.should eq "{red-fg}abc{/}"
    end

    it "emits nil-colored characters bare, splitting the tagged runs" do
      s = String.build { |io| Crysterm::Widget::Graph::Scale.tagged_row(io, ['a', ' ', 'b'], ["red", nil, "blue"]) }
      s.should eq "{red-fg}a{/} {blue-fg}b{/}"
    end

    it "produces empty output for an empty row" do
      s = String.build { |io| Crysterm::Widget::Graph::Scale.tagged_row(io, [] of Char, [] of String?) }
      s.should eq ""
    end
  end
end
