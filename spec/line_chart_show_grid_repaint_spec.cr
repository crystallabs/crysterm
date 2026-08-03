require "./spec_helper"

include Crysterm

# `Widget::Graph::LineChart` draws its optional grid lines on the plot
# `Graph::Canvas` (in `#paint_plot`, gated by `show_grid?`). The Canvas only
# re-rasterizes when its `@paint_dirty` flag is set. Data mutators
# (`#add_series`/`#clear_series`/`#refresh`) call `plot.invalidate_paint`;
# `show_grid=` must invalidate the plot raster and schedule a render too — a
# plain `property?` setter would leave the *old* grid state painted on window
# until an unrelated repaint.

describe "Widget::Graph::LineChart#show_grid= schedules a plot repaint" do
  it "marks the plot Canvas dirty when the grid is toggled" do
    s = headless_screen(60, 20)
    c = Crysterm::Widget::Graph::LineChart.new parent: s, top: 0, left: 0,
      width: 50, height: 16, show_grid: true
    c.add_line "a", [{0.0, 0.0}, {1.0, 1.0}, {2.0, 0.5}]
    s.repaint
    # After a render the plot Canvas has painted and cleared its dirty flag.
    c.plot.@paint_dirty.should be_false

    c.show_grid = false

    # The plotted grid changed, so the Canvas must repaint.
    c.plot.@paint_dirty.should be_true
  end

  it "does not mark dirty on a no-op assignment (unchanged value)" do
    s = headless_screen(60, 20)
    c = Crysterm::Widget::Graph::LineChart.new parent: s, top: 0, left: 0,
      width: 50, height: 16, show_grid: true
    c.add_line "a", [{0.0, 0.0}, {1.0, 1.0}]
    s.repaint
    c.plot.@paint_dirty.should be_false

    c.show_grid = true # same value

    c.plot.@paint_dirty.should be_false
  end
end
