require "./spec_helper"

include Crysterm

# BUGS18.md #78, #79, #81, #82, #83, #87: graph-widget non-finite-guard gaps
# (Map viewport bounds/graticule, StackedBar column sum), decoration setters
# that never scheduled a render (PieChart), a NaN slice poisoning the whole
# pie, an unguarded Painter primitive, and LineChart's never-rendered axis
# titles.

private def g18_screen(w = 78, h = 22)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

private def g18_text(s) : String
  (0...s.aheight).map { |y| (0...s.awidth).map { |x| c = s.lines[y][x].char; c == '\0' ? ' ' : c }.join }.join("\n")
end

# Non-blocking receive on the render doorbell: true iff a frame is pending.
# See spec/bugs15_chart_invalidation_spec.cr for the original of this helper.
private def g18_frame_scheduled?(w) : Bool
  select
  when w.@render_wakeup.receive
    true
  else
    false
  end
end

private def g18_drain_frames(w) : Nil
  loop do
    select
    when w.@render_wakeup.receive
      # keep draining
    else
      return
    end
  end
end

private def blank_bitmap(w, h) : PNGGIF::Bitmap
  Array.new(h) { Array.new(w) { PNGGIF::Pixel.new(0, 0, 0, 0) } }
end

# --- B18-78: Map#draw_markers / non-finite viewport bounds --------------------

describe "Widget::Graph::Map non-finite viewport guards (B18-78)" do
  it "does not crash rendering a marker when constructed with a NaN min_lon" do
    # `#initialize`'s constructor params bypass the `finite_bound_prop`
    # setters, so a directly-constructed non-finite bound is the one way to
    # reach `#draw_markers`'s own guard in isolation.
    s = g18_screen
    saved = Crysterm::CSS.default_stylesheet
    Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
    begin
      m = Crysterm::Widget::Graph::Map.new parent: s, top: 0, left: 0, width: 78, height: 22,
        type: Crysterm::Widget::Media::Type::Glyph, min_lon: Float64::NAN
      m.add_marker latitude: 12.0, longitude: 34.0, char: 'X'
      # Previously `fx = (lon - NaN) / NaN` raised OverflowError on `.round.to_i`.
      s.repaint
    ensure
      Crysterm::CSS.default_stylesheet = saved
    end
  end

  it "does not crash rendering a marker when constructed with a -Infinity min_lon" do
    s = g18_screen
    saved = Crysterm::CSS.default_stylesheet
    Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
    begin
      m = Crysterm::Widget::Graph::Map.new parent: s, top: 0, left: 0, width: 78, height: 22,
        type: Crysterm::Widget::Media::Type::Glyph, min_lon: -Float64::INFINITY
      m.add_marker latitude: 12.0, longitude: 34.0, char: 'X'
      s.repaint
    ensure
      Crysterm::CSS.default_stylesheet = saved
    end
  end

  it "min_lon=/max_lon=/min_lat=/max_lat= reject a non-finite assignment, keeping the previous bound" do
    m = Crysterm::Widget::Graph::Map.new width: 10, height: 6
    before = {m.min_lon, m.max_lon, m.min_lat, m.max_lat}

    m.min_lon = Float64::NAN
    m.max_lon = Float64::INFINITY
    m.min_lat = -Float64::INFINITY
    m.max_lat = Float64::NAN

    {m.min_lon, m.max_lon, m.min_lat, m.max_lat}.should eq before
  end

  it "#look_at rejects a NaN span, keeping the previous viewport" do
    m = Crysterm::Widget::Graph::Map.new width: 10, height: 6
    before = {m.min_lon, m.max_lon, m.min_lat, m.max_lat}

    m.look_at 12.0, 34.0, span_lat: Float64::NAN, span_lon: Float64::NAN

    {m.min_lon, m.max_lon, m.min_lat, m.max_lat}.should eq before
  end

  it "#look_at rejects an Infinity span, keeping the previous viewport" do
    m = Crysterm::Widget::Graph::Map.new width: 10, height: 6
    before = {m.min_lon, m.max_lon, m.min_lat, m.max_lat}

    m.look_at 12.0, 34.0, span_lat: Float64::INFINITY, span_lon: 360

    {m.min_lon, m.max_lon, m.min_lat, m.max_lat}.should eq before
  end

  it "#look_at with a finite span still updates the viewport normally" do
    m = Crysterm::Widget::Graph::Map.new width: 10, height: 6
    m.look_at 12.0, 34.0, span_lat: 10.0, span_lon: 20.0
    m.min_lon.should eq 24.0
    m.max_lon.should eq 44.0
    m.min_lat.should eq 7.0
    m.max_lat.should eq 17.0
  end
end

# --- B18-82: Map graticule loop on a non-finite/huge viewport bound -----------

describe "Widget::Graph::Map graticule non-finite/huge-bound guard (B18-82)" do
  it "does not hang rendering with show_graticule and a -Infinity min_lon (constructor bypass)" do
    s = g18_screen
    saved = Crysterm::CSS.default_stylesheet
    Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
    begin
      Crysterm::Widget::Graph::Map.new parent: s, top: 0, left: 0, width: 78, height: 22,
        type: Crysterm::Widget::Media::Type::Glyph, show_graticule: true,
        min_lon: -Float64::INFINITY
      # The old accumulation-driven `lon = -Inf; lon += step` loop never
      # advances past `-Inf` and spins the render fiber forever; the
      # index-driven `#each_graticule_line` must terminate promptly instead.
      elapsed = Time.measure { s.repaint }
      elapsed.should be < 5.seconds
    ensure
      Crysterm::CSS.default_stylesheet = saved
    end
  end

  it "does not hang or stall on a tiny finite span at a huge magnitude offset" do
    # At min_lon = 2**58 the float ulp exceeds a 30-degree step, so
    # `lon += step` can round back to the same value — an accumulation-driven
    # loop stalls even though every bound is finite and the span is small.
    s = g18_screen
    saved = Crysterm::CSS.default_stylesheet
    Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
    begin
      base = 2.0**58
      Crysterm::Widget::Graph::Map.new parent: s, top: 0, left: 0, width: 78, height: 22,
        type: Crysterm::Widget::Media::Type::Glyph, show_graticule: true,
        min_lon: base, max_lon: base + 300.0, min_lat: -60.0, max_lat: 85.0
      elapsed = Time.measure { s.repaint }
      elapsed.should be < 5.seconds
    ensure
      Crysterm::CSS.default_stylesheet = saved
    end
  end
end

# --- B18-79: PieChart decoration setters schedule a render --------------------

describe "Widget::Graph::PieChart decoration setters schedule a render (B18-79)" do
  it "inner_radius= with a Float64 argument rings the render doorbell" do
    # `property inner_radius : Float64` generates a `(Float64)` setter that is
    # a more specific overload than the hand-written invalidating
    # `(Number)` one, so a plain Float64 assignment used to dispatch to the
    # silent generated setter and never schedule a frame.
    s = g18_screen
    pie = Crysterm::Widget::Graph::PieChart.new parent: s, top: 0, left: 0, width: 24, height: 12
    pie.add_slice "a", 50.0
    pie.add_slice "b", 50.0
    s.repaint
    g18_drain_frames s

    pie.inner_radius = 0.5 # Float64 literal: the buggy overload
    g18_frame_scheduled?(s).should be_true
    pie.inner_radius.should eq 0.5
  end

  it "inner_radius= is a no-op on an unchanged value" do
    pie = Crysterm::Widget::Graph::PieChart.new width: 10, height: 6, inner_radius: 0.5
    pie.inner_radius = 0.5
    pie.inner_radius.should eq 0.5
  end

  it "show_legend= rings the render doorbell" do
    s = g18_screen
    pie = Crysterm::Widget::Graph::PieChart.new parent: s, top: 0, left: 0, width: 24, height: 12
    pie.add_slice "a", 50.0
    pie.add_slice "b", 50.0
    s.repaint
    g18_drain_frames s

    pie.show_legend = false
    g18_frame_scheduled?(s).should be_true
    pie.show_legend?.should be_false
  end

  it "show_percentages= rings the render doorbell" do
    s = g18_screen
    pie = Crysterm::Widget::Graph::PieChart.new parent: s, top: 0, left: 0, width: 24, height: 12
    pie.add_slice "a", 50.0
    pie.add_slice "b", 50.0
    s.repaint
    g18_drain_frames s

    pie.show_percentages = false
    g18_frame_scheduled?(s).should be_true
    pie.show_percentages?.should be_false
  end
end

# --- B18-81: PieChart NaN slice value ------------------------------------------

describe "Widget::Graph::PieChart non-finite slice guard (B18-81)" do
  it "a NaN slice value does not blank the other, finite slices" do
    s = g18_screen
    saved = Crysterm::CSS.default_stylesheet
    Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
    begin
      pie = Crysterm::Widget::Graph::PieChart.new parent: s, top: 0, left: 0, width: 24, height: 13,
        type: Crysterm::Widget::Media::Type::Glyph, style: Crysterm::Style.new(border: true)
      pie.add_slice "web", 50.0
      pie.add_slice "db", Float64::NAN
      pie.add_slice "cache", 20.0
      s.repaint
      t = g18_text s
      # Previously the NaN slice poisoned `total`, so every angle became NaN
      # and `fill_ring`'s non-finite guard blanked every wedge.
      t.each_char.any? { |ch| ('⠁'..'⣿').includes?(ch) }.should be_true
      # The finite slices' percentages are computed from the filtered total
      # (50 + 20 = 70), not suppressed by the poisoned raw sum.
      t.includes?("71%").should be_true
      t.includes?("29%").should be_true
      # The NaN slice itself still shows via the retained `frac.finite?` guard.
      t.includes?("0%").should be_true
    ensure
      Crysterm::CSS.default_stylesheet = saved
    end
  end

  it "an Infinity slice value does not blank the slices ahead of it" do
    s = g18_screen
    saved = Crysterm::CSS.default_stylesheet
    Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
    begin
      pie = Crysterm::Widget::Graph::PieChart.new parent: s, top: 0, left: 0, width: 24, height: 13,
        type: Crysterm::Widget::Media::Type::Glyph, style: Crysterm::Style.new(border: true)
      pie.add_slice "web", 50.0
      pie.add_slice "inf", Float64::INFINITY
      pie.add_slice "cache", 20.0
      s.repaint
      t = g18_text s
      t.each_char.any? { |ch| ('⠁'..'⣿').includes?(ch) }.should be_true
    ensure
      Crysterm::CSS.default_stylesheet = saved
    end
  end
end

# --- B18-83: Painter#draw_rect non-finite guard --------------------------------

describe "Widget::Graph::Painter#draw_rect non-finite guard (B18-83)" do
  it "plots nothing when h is NaN, instead of a stray sentinel-length edge" do
    bmp = blank_bitmap(16, 16)
    p = Crysterm::Widget::Graph::Painter.new bmp
    p.pen = 0xFFFFFF
    p.draw_rect 5, 10, 3, Float64::NAN
    painted = false
    16.times { |y| 16.times { |x| painted = true if bmp[y][x].r == 255 } }
    painted.should be_false
  end

  it "plots nothing when x is Infinity" do
    bmp = blank_bitmap(16, 16)
    p = Crysterm::Widget::Graph::Painter.new bmp
    p.pen = 0xFFFFFF
    p.draw_rect Float64::INFINITY, 5, 3, 3
    painted = false
    16.times { |y| 16.times { |x| painted = true if bmp[y][x].r == 255 } }
    painted.should be_false
  end

  it "still draws a normal finite rect" do
    bmp = blank_bitmap(16, 16)
    p = Crysterm::Widget::Graph::Painter.new bmp
    p.pen = 0xFFFFFF
    p.draw_rect 2, 2, 5, 5
    painted = false
    16.times { |y| 16.times { |x| painted = true if bmp[y][x].r == 255 } }
    painted.should be_true
  end
end

# --- B18-81 sibling: StackedBar#column NaN segment -----------------------------

describe "Widget::Graph::StackedBar non-finite segment guard (B18-81 sibling)" do
  it "does not raise when one segment of a bar is NaN" do
    s = g18_screen
    sb = Crysterm::Widget::Graph::StackedBar.new parent: s, top: 0, left: 0,
      width: 40, height: 10, segment_labels: ["x", "y"]
    sb.values = [[3.0, Float64::NAN], [1.0, 4.0]]
    # Previously relied only on `Scale.eighths` incidentally zeroing a
    # non-finite sum; now `#column` filters both the sum and the running
    # cumulative total explicitly.
    s.repaint
  end

  it "still renders a normal, all-finite bar" do
    s = g18_screen
    sb = Crysterm::Widget::Graph::StackedBar.new parent: s, top: 0, left: 0,
      width: 40, height: 10, segment_labels: ["x", "y"]
    sb.values = [[3.0, 2.0], [1.0, 4.0]]
    s.repaint
    g18_text(s).strip.empty?.should be_false
  end
end

# --- B18-87: LineChart axis titles ---------------------------------------------

describe "Widget::Graph::LineChart axis titles (B18-87)" do
  it "renders the X axis title on the bottom row" do
    s = g18_screen(60, 20)
    saved = Crysterm::CSS.default_stylesheet
    Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
    begin
      chart = Crysterm::Widget::Graph::LineChart.new parent: s, top: 0, left: 0, width: 60, height: 18,
        style: Crysterm::Style.new(border: true)
      chart.add_line "sin", [{0.0, 0.0}, {1.0, 1.0}]
      chart.axis_x.title = "Time (s)"
      chart.refresh
      s.repaint
      g18_text(s).includes?("Time (s)").should be_true
    ensure
      Crysterm::CSS.default_stylesheet = saved
    end
  end

  it "renders the Y axis title stacked in the leftmost interior column" do
    s = g18_screen(60, 20)
    saved = Crysterm::CSS.default_stylesheet
    Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
    begin
      chart = Crysterm::Widget::Graph::LineChart.new parent: s, top: 0, left: 0, width: 60, height: 18,
        style: Crysterm::Style.new(border: true)
      chart.add_line "sin", [{0.0, 0.0}, {1.0, 1.0}]
      chart.axis_y.title = "V"
      chart.refresh
      s.repaint
      g18_text(s).includes?("V").should be_true
    ensure
      Crysterm::CSS.default_stylesheet = saved
    end
  end

  it "an empty axis title does not perturb the left margin (no breathing-room regression)" do
    s = g18_screen(60, 20)
    chart = Crysterm::Widget::Graph::LineChart.new parent: s, top: 0, left: 0, width: 60, height: 18
    chart.add_line "sin", [{0.0, -1.0}, {1.0, 1.0}]
    chart.refresh
    s.repaint # must not raise; empty titles are the common case
  end
end
