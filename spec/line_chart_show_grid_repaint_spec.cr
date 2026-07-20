require "./spec_helper"

include Crysterm

# `Widget::Graph::LineChart` draws its optional grid lines on the plot
# `Graph::Canvas` (in `#paint_plot`, gated by `show_grid?`). The Canvas only
# re-rasterizes when its `@paint_dirty` flag is set. Data mutators
# (`#add_series`/`#clear_series`/`#refresh`) call `plot.invalidate_paint`, but
# `show_grid=` was a plain `property?` setter that did not — so toggling the
# grid left the *old* grid state painted on window until an unrelated repaint.
# `show_grid=` now invalidates the plot raster and schedules a render.

private def lcg_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 60,
    height: 20,
    default_quit_keys: false)
end

describe "Widget::Graph::LineChart#show_grid= schedules a plot repaint" do
  it "marks the plot Canvas dirty when the grid is toggled" do
    s = lcg_screen
    c = Crysterm::Widget::Graph::LineChart.new parent: s, top: 0, left: 0,
      width: 50, height: 16, show_grid: true
    c.add_line "a", [{0.0, 0.0}, {1.0, 1.0}, {2.0, 0.5}]
    s.repaint
    # After a render the plot Canvas has painted and cleared its dirty flag.
    c.plot.@paint_dirty.should be_false

    c.show_grid = false

    # The plotted grid changed, so the Canvas must repaint (was stale before).
    c.plot.@paint_dirty.should be_true
  end

  it "does not mark dirty on a no-op assignment (unchanged value)" do
    s = lcg_screen
    c = Crysterm::Widget::Graph::LineChart.new parent: s, top: 0, left: 0,
      width: 50, height: 16, show_grid: true
    c.add_line "a", [{0.0, 0.0}, {1.0, 1.0}]
    s.repaint
    c.plot.@paint_dirty.should be_false

    c.show_grid = true # same value

    c.plot.@paint_dirty.should be_false
  end
end
