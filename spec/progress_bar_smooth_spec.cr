require "./spec_helper"

include Crysterm

# `ProgressBar#smooth?` is the sub-cell fill folded out of `Gauge`: the cell at
# the fill boundary carries a partial block glyph, so the bar advances in
# eighths of a cell rather than whole cells. `Gauge` is the same knob with the
# opposite default (on), and both measure through `Graph::Scale.eighths`, so one
# value fills identically in either widget.

private def smooth_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false, force_unicode: true)
end

private def damage_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false, force_unicode: true,
    optimization: Crysterm::OptimizationFlag::DamageTracking)
end

# The first *cols* characters of rendered row *y*.
private def row_chars(s : Crysterm::Window, y : Int32, cols : Int32) : String
  String.build { |io| cols.times { |x| io << s.@lines[y][x].char } }
end

describe "ProgressBar#smooth?" do
  it "defaults off — the fill advances in whole cells" do
    s = smooth_screen
    Widget::ProgressBar.new parent: s, top: 0, left: 0, width: 10, height: 1,
      value: 45, minimum: 0, maximum: 100
    s.repaint
    # 45% of 10 cells is 4.5: four filled cells, and the boundary cell stays
    # blank rather than showing half a block.
    row_chars(s, 0, 10).should eq "          "
  end

  it "fills the boundary cell with a partial block when set" do
    s = smooth_screen
    Widget::ProgressBar.new parent: s, top: 0, left: 0, width: 10, height: 1,
      value: 45, minimum: 0, maximum: 100, smooth: true
    s.repaint
    # 45% == 36 eighths == 4 whole cells + 4/8 of the fifth.
    row_chars(s, 0, 10).should eq "    ▌     "
  end

  it "draws no partial cell when the fill lands on a cell boundary" do
    s = smooth_screen
    Widget::ProgressBar.new parent: s, top: 0, left: 0, width: 10, height: 1,
      value: 50, minimum: 0, maximum: 100, smooth: true
    s.repaint
    row_chars(s, 0, 10).should eq "          "
  end

  it "measures against the raw range, not the rounded percentage" do
    s = smooth_screen
    # 1/16 of the range: half a cell of a bar 8 cells wide. The rounded
    # percentage (6) would place the boundary an eighth off.
    Widget::ProgressBar.new parent: s, top: 0, left: 0, width: 8, height: 1,
      value: 1, minimum: 0, maximum: 16, smooth: true
    s.repaint
    row_chars(s, 0, 8).should eq "▌       "
  end

  it "fills a vertical bar upward, partial cell on top" do
    s = smooth_screen
    Widget::ProgressBar.new parent: s, top: 0, left: 0, width: 1, height: 10,
      value: 45, minimum: 0, maximum: 100, smooth: true, orientation: :vertical
    s.repaint
    # Four filled rows at the bottom (6..9), the half-filled cell above them.
    s.@lines[5][0].char.should eq '▄'
    (6..9).each { |y| s.@lines[y][0].char.should eq ' ' }
    (0..4).each { |y| s.@lines[y][0].char.should eq ' ' }
  end

  it "schedules a repaint when toggled" do
    s = damage_screen
    pb = Widget::ProgressBar.new parent: s, top: 0, left: 0, width: 10, height: 1,
      value: 45, minimum: 0, maximum: 100
    s.repaint
    s.@damage_dirty_roots.clear
    pb.smooth = true
    pb.smooth?.should be_true
    s.@damage_dirty_roots.includes?(pb).should be_true
  end
end

describe "Gauge#smooth?" do
  it "defaults on — the sub-cell fill is unchanged" do
    s = smooth_screen
    g = Widget::Gauge.new parent: s, top: 0, left: 0, width: 10, height: 1,
      value: 45, show_label: false
    g.smooth?.should be_true
    s.repaint
    row_chars(s, 0, 10).should eq "████▌     "
  end

  it "falls back to a whole-cell fill when unset" do
    s = smooth_screen
    Widget::Gauge.new parent: s, top: 0, left: 0, width: 10, height: 1,
      value: 45, show_label: false, smooth: false
    s.repaint
    row_chars(s, 0, 10).should eq "████      "
  end

  it "rebuilds the content when toggled" do
    s = smooth_screen
    g = Widget::Gauge.new parent: s, top: 0, left: 0, width: 10, height: 1,
      value: 45, show_label: false
    s.repaint
    g.smooth = false
    s.repaint
    row_chars(s, 0, 10).should eq "████      "
  end

  it "leaves stacked mode whole-cell either way" do
    s = smooth_screen
    segs = [Widget::Gauge::Segment.new(45), Widget::Gauge::Segment.new(55)]
    g = Widget::Gauge.new parent: s, top: 0, left: 0, width: 10, height: 1,
      show_label: false, segments: segs
    s.repaint
    smooth_row = row_chars s, 0, 10
    g.smooth = false
    s.repaint
    row_chars(s, 0, 10).should eq smooth_row
  end
end

describe "Graph::Scale.whole_cells" do
  it "drops the partial cell rather than rounding it up" do
    Widget::Graph::Scale.whole_cells(36).should eq 32
    Widget::Graph::Scale.whole_cells(39).should eq 32
    Widget::Graph::Scale.whole_cells(40).should eq 40
    Widget::Graph::Scale.whole_cells(0).should eq 0
  end
end
