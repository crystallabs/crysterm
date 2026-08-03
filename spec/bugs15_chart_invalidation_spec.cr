require "./spec_helper"

include Crysterm

# Chart/graph property setters that mutate an ivar must also schedule a frame
# (otherwise the change stays invisible on an idle screen); plus two
# cache-invalidation gaps (BarChart's content cache must include the
# glyph-ramp inputs; LineChart axis mutations must re-rasterize the plot
# Canvas, not just the tick chrome).

# Non-blocking receive on the render doorbell: true iff a frame is pending.
# The setters under test must ring this doorbell (via `mark_dirty` ->
# `request_frame`) so an idle screen actually repaints. Consumes one token.
private def frame_scheduled?(w) : Bool
  select
  when w.@render_wakeup.receive
    true
  else
    false
  end
end

# Empties the coalescing doorbell so a later `frame_scheduled?` observes only
# tokens rung after this point.
private def drain_frames(w) : Nil
  loop do
    select
    when w.@render_wakeup.receive
      # keep draining
    else
      return
    end
  end
end

# A stable signature of a Canvas's painted bitmap, so a repaint (or its absence)
# is observable across renders.
private def bitmap_sig(canvas) : String
  bmp = canvas.@bitmap
  return "" unless bmp
  String.build do |io|
    bmp.each do |row|
      row.each { |px| io << px.r << ',' << px.g << ',' << px.b << ',' << px.a << ';' }
    end
  end
end

describe "Widget::Graph::Bar decoration setters schedule a render (#70)" do
  it "bar_width= (a chart_prop setter) rings the render doorbell" do
    s = headless_screen(80, 24)
    bar = Crysterm::Widget::Graph::Bar.new parent: s, top: 0, left: 0,
      width: 40, height: 8
    bar.values = [1.0, 2.0, 3.0]
    s.repaint
    drain_frames s

    bar.bar_width = 3
    frame_scheduled?(s).should be_true
  end

  it "labels= (a chart_prop setter) rings the render doorbell" do
    s = headless_screen(80, 24)
    bar = Crysterm::Widget::Graph::Bar.new parent: s, top: 0, left: 0,
      width: 40, height: 8
    bar.values = [1.0, 2.0, 3.0]
    s.repaint
    drain_frames s

    bar.labels = ["a", "b", "c"]
    frame_scheduled?(s).should be_true
  end

  it "show_values= rings the render doorbell" do
    s = headless_screen(80, 24)
    bar = Crysterm::Widget::Graph::Bar.new parent: s, top: 0, left: 0,
      width: 40, height: 8
    bar.values = [1.0, 2.0, 3.0]
    s.repaint
    drain_frames s

    bar.show_values = true
    frame_scheduled?(s).should be_true
  end
end

describe "Widget::Graph::StackedBar decoration setters schedule a render (#70)" do
  it "show_legend= rings the render doorbell" do
    s = headless_screen(80, 24)
    sb = Crysterm::Widget::Graph::StackedBar.new parent: s, top: 0, left: 0,
      width: 40, height: 10, segment_labels: ["x", "y"]
    sb.values = [[3.0, 2.0], [1.0, 4.0]]
    s.repaint
    drain_frames s

    sb.show_legend = false
    frame_scheduled?(s).should be_true
  end

  it "max= (a chart_prop setter) rings the render doorbell" do
    s = headless_screen(80, 24)
    sb = Crysterm::Widget::Graph::StackedBar.new parent: s, top: 0, left: 0,
      width: 40, height: 10
    sb.values = [[3.0, 2.0], [1.0, 4.0]]
    s.repaint
    drain_frames s

    sb.maximum = 20.0
    frame_scheduled?(s).should be_true
  end
end

describe "Widget::Graph::LineChart chrome setters schedule a render (#77)" do
  it "title= rings the render doorbell on an actual change" do
    s = headless_screen(80, 24)
    lc = Crysterm::Widget::Graph::LineChart.new parent: s, top: 0, left: 0,
      width: 40, height: 12
    lc.add_line "s", [{0.0, 1.0}, {1.0, 3.0}, {2.0, 2.0}]
    s.repaint
    drain_frames s

    lc.title = "CPU load"
    frame_scheduled?(s).should be_true
  end

  it "title= is a no-op (no frame) when the value is unchanged" do
    s = headless_screen(80, 24)
    lc = Crysterm::Widget::Graph::LineChart.new parent: s, top: 0, left: 0,
      width: 40, height: 12, title: "same"
    s.repaint
    drain_frames s

    lc.title = "same"
    frame_scheduled?(s).should be_false
  end

  it "show_legend= rings the render doorbell on an actual change" do
    s = headless_screen(80, 24)
    lc = Crysterm::Widget::Graph::LineChart.new parent: s, top: 0, left: 0,
      width: 40, height: 12, show_legend: false
    lc.add_line "s", [{0.0, 1.0}, {1.0, 3.0}]
    s.repaint
    drain_frames s

    lc.show_legend = true
    frame_scheduled?(s).should be_true
  end
end

describe "Widget::Graph::Bar content cache tracks the glyph ramp (#78)" do
  it "rebuilds the tagged content when style.glyphs changes (same size/data)" do
    s = headless_screen(80, 24)
    bar = Crysterm::Widget::Graph::Bar.new parent: s, top: 0, left: 0,
      width: 20, height: 8
    bar.values = [1.0, 2.0, 3.0, 4.0]
    s.repaint
    before = bar.content

    # A CSS `glyphs:` hot-reload / tier upgrade changes the resolved fill ramp
    # with no change to size or data; the cached content must not be reused.
    bar.style.glyphs = " .:-=+*#%@"
    s.repaint
    after = bar.content

    after.should_not eq before
    # The new ramp's glyphs actually reach the built content.
    after.should contain('@')
  end
end

describe "Widget::Graph::Donut overlay setters schedule a render (#87)" do
  it "label= rings the render doorbell on an actual change" do
    s = headless_screen(80, 24)
    d = Crysterm::Widget::Graph::Donut.new parent: s, top: 0, left: 0,
      width: 20, height: 10, value: 72
    s.repaint
    drain_frames s

    d.label = "CPU"
    frame_scheduled?(s).should be_true
  end

  it "format= rings the render doorbell on an actual change" do
    s = headless_screen(80, 24)
    d = Crysterm::Widget::Graph::Donut.new parent: s, top: 0, left: 0,
      width: 20, height: 10, value: 72
    s.repaint
    drain_frames s

    d.format = "%v"
    frame_scheduled?(s).should be_true
  end

  it "show_label= rings the render doorbell on an actual change" do
    s = headless_screen(80, 24)
    d = Crysterm::Widget::Graph::Donut.new parent: s, top: 0, left: 0,
      width: 20, height: 10, value: 72
    s.repaint
    drain_frames s

    d.show_label = false
    frame_scheduled?(s).should be_true
  end

  it "show_label= is a no-op (no frame) when unchanged" do
    s = headless_screen(80, 24)
    d = Crysterm::Widget::Graph::Donut.new parent: s, top: 0, left: 0,
      width: 20, height: 10, value: 72, show_label: true
    s.repaint
    drain_frames s

    d.show_label = true
    frame_scheduled?(s).should be_false
  end
end

describe "Widget::Graph::HeatMap overlay setters schedule a render (#87)" do
  it "show_legend= rings the render doorbell on an actual change" do
    s = headless_screen(80, 24)
    h = Crysterm::Widget::Graph::HeatMap.new parent: s, top: 0, left: 0,
      width: 30, height: 12, values: [[1.0, 2.0], [3.0, 4.0]]
    s.repaint
    drain_frames s

    h.show_legend = false
    frame_scheduled?(s).should be_true
  end

  it "show_labels= rings the render doorbell on an actual change" do
    s = headless_screen(80, 24)
    h = Crysterm::Widget::Graph::HeatMap.new parent: s, top: 0, left: 0,
      width: 30, height: 12, values: [[1.0, 2.0], [3.0, 4.0]]
    s.repaint
    drain_frames s

    h.show_labels = false
    frame_scheduled?(s).should be_true
  end
end

describe "Widget::Graph::LineChart axis mutation re-rasterizes the plot (#88)" do
  it "repaints the plot Canvas when axis_y.maximum changes (non-resizing render)" do
    s = headless_screen(80, 24)
    lc = Crysterm::Widget::Graph::LineChart.new parent: s, top: 0, left: 0,
      width: 40, height: 12
    lc.add_line "s", [{0.0, 1.0}, {1.0, 5.0}, {2.0, 3.0}]
    s.repaint
    before = bitmap_sig(lc.plot)

    # Change only the Y scale (no #refresh, no resize). The chrome re-scales;
    # the plot raster must not stay at the old auto-range and disagree.
    lc.axis_y.maximum = 100.0
    s.repaint
    after = bitmap_sig(lc.plot)

    after.should_not eq before
  end
end
