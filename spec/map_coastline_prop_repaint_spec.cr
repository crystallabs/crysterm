require "./spec_helper"

include Crysterm

# `Widget::Graph::Map` projects/draws its coastlines on a `Graph::Canvas` (in
# `#paint_map`), which only re-rasterizes when its `@paint_dirty` flag is set.
# `#look_at`/`#refresh` call `canvas.invalidate_paint`; the viewport and
# coastline/graticule setters (`min_lon`/`max_lon`/`min_lat`/`max_lat`,
# `land_color`, `show_graticule`, `graticule_color`, `graticule_step`) must
# invalidate the raster and schedule a render too — the docstring lists setting
# the bounds directly as a supported path, and a plain `property` setter would
# leave the old projection painted on window. (Markers are a separate text
# overlay and keep their own path.)

describe "Widget::Graph::Map coastline setters schedule a repaint" do
  it "marks the Canvas dirty when a viewport bound changes" do
    s = headless_screen(80, 24)
    m = Crysterm::Widget::Graph::Map.new parent: s, top: 0, left: 0, width: 70, height: 20
    s.repaint
    m.canvas.@paint_dirty.should be_false

    m.min_lon = -90.0

    m.canvas.@paint_dirty.should be_true
  end

  it "marks the Canvas dirty when the coastline color or graticule changes" do
    s = headless_screen(80, 24)
    m = Crysterm::Widget::Graph::Map.new parent: s, top: 0, left: 0, width: 70, height: 20
    s.repaint
    m.canvas.@paint_dirty.should be_false
    m.land_color = 0xFF0000
    m.canvas.@paint_dirty.should be_true

    s.repaint
    m.canvas.@paint_dirty.should be_false
    m.show_graticule = true
    m.canvas.@paint_dirty.should be_true
  end

  it "does not mark dirty on a no-op assignment (unchanged value)" do
    s = headless_screen(80, 24)
    m = Crysterm::Widget::Graph::Map.new parent: s, top: 0, left: 0, width: 70, height: 20
    s.repaint
    m.canvas.@paint_dirty.should be_false

    m.min_lon = m.min_lon # same value

    m.canvas.@paint_dirty.should be_false
  end
end
