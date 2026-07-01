require "./spec_helper"

include Crysterm

# Render-level specs for the block-glyph graphing widgets (`Graph::Bar`,
# `Graph::StackedBar`, `Widget::Gauge`). Drives a synchronous render on an
# in-memory screen and inspects the cell buffer.

private def render_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24)
end

private def row_chars(s, y, x0, x1)
  line = s.lines[y]
  (x0...x1).map { |x| line[x].char }.join
end

describe "Graph::Bar rendering" do
  it "draws a full bar at max and an empty one at min" do
    s = render_screen
    Crysterm::Widget::Graph::Bar.new parent: s, top: 0, left: 0, width: 2, height: 2,
      min: 0.0, max: 1.0, values: [1.0, 0.0]
    s._render
    # Left column full (two stacked full blocks), right column empty.
    row_chars(s, 0, 0, 2).should eq "█ "
    row_chars(s, 1, 0, 2).should eq "█ "
  end

  it "uses eighth-blocks for sub-cell heights" do
    s = render_screen
    Crysterm::Widget::Graph::Bar.new parent: s, top: 0, left: 0, width: 1, height: 1,
      min: 0.0, max: 1.0, values: [0.5]
    s._render
    # Half of one cell -> the 4/8 block.
    row_chars(s, 0, 0, 1).should eq "▄"
  end

  it "shows category labels under the bars" do
    s = render_screen
    Crysterm::Widget::Graph::Bar.new parent: s, top: 0, left: 0, width: 3, height: 3,
      min: 0.0, max: 1.0, bar_width: 3, values: [1.0], labels: ["cpu"]
    s._render
    # Bottom row is the label, plot rows above are the full bar.
    row_chars(s, 0, 0, 3).should eq "███"
    row_chars(s, 2, 0, 3).should eq "cpu"
  end

  it "aligns category labels with the shown (tail) bars when values overflow" do
    s = render_screen
    # Width fits 2 bars but 3 values are given, so only the last two show;
    # labels must be the matching tail ("two"/"thr"), not the leading ones.
    Crysterm::Widget::Graph::Bar.new parent: s, top: 0, left: 0, width: 7, height: 2,
      min: 0.0, max: 1.0, bar_width: 3, bar_spacing: 1,
      values: [1.0, 1.0, 1.0], labels: ["one", "two", "thr"]
    s._render
    row_chars(s, 1, 0, 7).should eq "two thr"
  end
end

describe "Graph::StackedBar rendering" do
  it "stacks segments bottom-up in their colors" do
    s = render_screen
    # One bar of height 2 cells, two equal segments -> one cell each.
    Crysterm::Widget::Graph::StackedBar.new parent: s, top: 0, left: 0, width: 1, height: 2,
      max: 2.0, bar_width: 1, show_legend: false, values: [[1.0, 1.0]]
    s._render
    row_chars(s, 0, 0, 1).should eq "█" # top segment
    row_chars(s, 1, 0, 1).should eq "█" # bottom segment
  end

  it "renders the topmost segment with a sub-cell partial block" do
    s = render_screen
    # Bar of 2 cells, single segment at 3/4 height -> bottom cell full, top
    # cell a 4/8 partial block.
    Crysterm::Widget::Graph::StackedBar.new parent: s, top: 0, left: 0, width: 1, height: 2,
      max: 1.0, bar_width: 1, show_legend: false, values: [[0.75]]
    s._render
    row_chars(s, 0, 0, 1).should eq "▄" # 4/8 partial top
    row_chars(s, 1, 0, 1).should eq "█" # full bottom
  end

  it "drops a legend entry that does not fit, counting the inter-entry space" do
    s = render_screen
    # Width 8: "█ ab" (4 cells) fits; a second entry needs 5 more cells
    # (separator included) and would overrun, so it's omitted entirely.
    Crysterm::Widget::Graph::StackedBar.new parent: s, top: 0, left: 0, width: 8, height: 2,
      bar_width: 1, show_legend: true, segment_labels: %w[ab cd], values: [[1.0, 1.0]]
    s._render
    # Row 0 is the legend; only the first entry appears, the rest blank.
    row_chars(s, 0, 0, 8).should eq "█ ab    "
  end
end

describe "Gauge rendering" do
  it "fills horizontally to the value's percentage" do
    s = render_screen
    Crysterm::Widget::Gauge.new parent: s, top: 0, left: 0, width: 4, height: 1,
      minimum: 0.0, maximum: 100.0, value: 100, show_label: false
    s._render
    row_chars(s, 0, 0, 4).should eq "████"
  end

  it "renders an empty bar at zero" do
    s = render_screen
    Crysterm::Widget::Gauge.new parent: s, top: 0, left: 0, width: 4, height: 1,
      minimum: 0.0, maximum: 100.0, value: 0, show_label: false
    s._render
    row_chars(s, 0, 0, 4).should eq "    "
  end

  it "emits DoubleValueChange when the value changes" do
    s = render_screen
    g = Crysterm::Widget::Gauge.new parent: s, top: 0, left: 0, width: 10, height: 1, value: 0
    got = nil
    g.on(Crysterm::Event::DoubleValueChange) { |e| got = e.value }
    g.value = 42
    got.should eq 42.0
  end
end
