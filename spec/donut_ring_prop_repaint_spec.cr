require "./spec_helper"

include Crysterm

# `Widget::Graph::Donut` draws its ring on a `Graph::Canvas`, which only
# re-rasterizes when its `@paint_dirty` flag is set. `#value=` is a custom
# setter that calls `canvas.invalidate_paint` (+ `request_render`), and the
# ring-shape/color setters (`thickness`, `fill_color`, `track_color`,
# `show_track`, `minimum`, `maximum`) must do the same — as plain `property`
# setters, e.g. `donut.thickness = 0.9` leaves the *old* ring on window until
# an unrelated repaint.

describe "Widget::Graph::Donut ring-parameter setters schedule a repaint" do
  it "marks the Canvas paint dirty when thickness changes" do
    s = headless_screen(40, 20)
    d = Crysterm::Widget::Graph::Donut.new parent: s, top: 0, left: 0,
      width: 18, height: 9, value: 50, thickness: 0.45
    s.repaint
    # After a render the Canvas has painted and cleared its dirty flag.
    d.canvas.@paint_dirty.should be_false

    d.thickness = 0.9

    # The ring geometry changed, so the Canvas must repaint (was stale before).
    d.canvas.@paint_dirty.should be_true
  end

  it "marks the Canvas paint dirty when the fill color changes" do
    s = headless_screen(40, 20)
    d = Crysterm::Widget::Graph::Donut.new parent: s, top: 0, left: 0,
      width: 18, height: 9, value: 50, fill_color: 0x40E0D0
    s.repaint
    d.canvas.@paint_dirty.should be_false

    d.fill_color = 0xE05050

    d.canvas.@paint_dirty.should be_true
  end

  it "does not mark dirty on a no-op assignment (unchanged value)" do
    s = headless_screen(40, 20)
    d = Crysterm::Widget::Graph::Donut.new parent: s, top: 0, left: 0,
      width: 18, height: 9, value: 50, thickness: 0.45
    s.repaint
    d.canvas.@paint_dirty.should be_false

    d.thickness = 0.45 # same value

    d.canvas.@paint_dirty.should be_false
  end
end
