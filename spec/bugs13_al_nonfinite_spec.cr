require "./spec_helper"

include Crysterm

# Regression specs for BUGS13 findings A3, A6, A7, A8 and A16 — non-finite
# (NaN/Infinity) data crashing the render fiber with OverflowError
# (`NaN.round.to_i` raises; NaN survives `clamp` because every comparison with
# NaN is false), plus the map graticule infinite loop.

private def nf_screen(w = 60, h = 20)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

describe "BUGS13 A3: NaN/Infinity sanitized in Gauge/GaugeList/Donut" do
  it "coerces a NaN Gauge value to the minimum and renders" do
    s = nf_screen
    g = Widget::Gauge.new parent: s, top: 0, left: 0, width: 20, height: 1, value: 50
    g.value = Float64::NAN
    g.value.should eq g.minimum
    s._render # must not raise OverflowError
  end

  it "sanitizes a non-finite construction-time Gauge value" do
    s = nf_screen
    g = Widget::Gauge.new parent: s, top: 2, left: 0, width: 20, height: 1,
      value: Float64::NAN
    g.value.should eq g.minimum
    s._render
  end

  it "renders a stacked Gauge whose segments contain NaN/Infinity values" do
    s = nf_screen
    g = Widget::Gauge.new parent: s, top: 4, left: 0, width: 20, height: 1
    g.segments = [
      Widget::Gauge::Segment.new(Float64::NAN, "red", "a"),
      Widget::Gauge::Segment.new(Float64::INFINITY, "green", "b"),
      Widget::Gauge::Segment.new(30, "blue", "c"),
    ]
    s._render # must not raise
  end

  it "coerces a NaN GaugeList value at ingestion and renders" do
    s = nf_screen
    gl = Widget::GaugeList.new parent: s, top: 6, left: 0, width: 30, height: 4
    gl.add_item "cpu", 64
    gl["cpu"] = Float64::NAN
    gl.gauges[0].value.should eq gl.minimum
    gl.add_item "mem", Float64::INFINITY
    gl.gauges[1].value.should eq gl.minimum
    gl[0] = Float64::NAN
    gl.gauges[0].value.should eq gl.minimum
    s._render # must not raise
  end

  it "coerces a NaN Donut value (readout uses percent.round.to_i) and renders" do
    s = nf_screen
    d = Widget::Graph::Donut.new parent: s, top: 0, left: 30, width: 18, height: 9,
      value: Float64::NAN
    d.value.should eq 0.0
    d.value = 50
    d.value = Float64::NAN
    d.value.should eq d.minimum
    s._render # must not raise
  end
end

describe "BUGS13 A6: LineChart filters non-finite points" do
  it "renders a chart whose series contain NaN/Infinity samples" do
    s = nf_screen 60, 20
    chart = Widget::Graph::LineChart.new parent: s, top: 0, left: 0,
      width: 50, height: 15, title: "t"
    chart.add_line "sig", [
      {0.0, Float64::NAN},
      {1.0, 2.0},
      {Float64::INFINITY, 3.0},
      {2.0, 4.0},
    ]
    s._render # crashed with OverflowError at the tick-label math before the fix
  end

  it "falls back to a sane range when an explicit axis bound is non-finite" do
    s = nf_screen 60, 20
    chart = Widget::Graph::LineChart.new parent: s, top: 0, left: 0,
      width: 50, height: 15
    chart.add_line "sig", [{0.0, 1.0}, {1.0, 2.0}]
    chart.axis_y.minimum = Float64::NAN
    chart.refresh
    s._render # must not raise
  end
end

describe "BUGS13 A7/A8: Map non-finite markers and graticule step" do
  it "rejects non-finite marker coordinates instead of crashing the render" do
    s = nf_screen 60, 20
    m = Widget::Graph::Map.new parent: s, top: 0, left: 0, width: 50, height: 15
    m.add_marker latitude: Float64::NAN, longitude: 10.0
    m.add_marker latitude: 10.0, longitude: Float64::NAN
    m.add_marker latitude: 40.71, longitude: -74.0, label: "NYC"
    s._render # the inverted NaN visibility filter crashed on .round.to_i before
  end

  it "terminates the graticule paint for a non-positive step" do
    s = nf_screen 60, 20
    m = Widget::Graph::Map.new parent: s, top: 0, left: 0, width: 50, height: 15,
      show_graticule: true
    m.graticule_step = -10.0
    s._render # infinite loop before the fix
    m.graticule_step = 0.0
    s._render
  end
end

describe "BUGS13 A16: PieChart legend survives non-finite slice values" do
  it "renders a legend with an Infinity slice without OverflowError" do
    s = nf_screen 60, 20
    pie = Widget::Graph::PieChart.new parent: s, top: 0, left: 0,
      width: 30, height: 15
    pie.add_slice 30, label: "a"
    pie.add_slice Float64::INFINITY, label: "b"
    s._render # Inf/Inf = NaN; NaN.round.to_i raised before the fix
  end
end
