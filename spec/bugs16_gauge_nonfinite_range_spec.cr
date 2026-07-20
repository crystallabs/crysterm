require "./spec_helper"

include Crysterm

# Regression specs for BUGS16 B16-38 and B16-41 — a non-finite (NaN/Infinity)
# range bound stored via `set_range` (Gauge, GaugeList, Graph::Donut), or a
# non-finite value assigned directly via `GaugeList::Item#value=`, would
# survive `clamp` (every NaN comparison is false) and crash the render fiber
# with OverflowError on `.round.to_i`.

private def nf_screen(w = 60, h = 20)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

describe "BUGS16 B16-38: Gauge/GaugeList/Donut set_range rejects non-finite bounds" do
  it "rejects a NaN Gauge#maximum, keeping the previous bound, and renders" do
    s = nf_screen
    g = Widget::Gauge.new parent: s, top: 0, left: 0, width: 20, height: 1, value: 50
    g.maximum = Float64::NAN
    g.maximum.should eq 100.0
    s.repaint # must not raise OverflowError
  end

  it "rejects a NaN Gauge#minimum, keeping the previous bound, and renders" do
    s = nf_screen
    g = Widget::Gauge.new parent: s, top: 2, left: 0, width: 20, height: 1, value: 50
    g.minimum = Float64::NAN
    g.minimum.should eq 0.0
    s.repaint
  end

  it "rejects a non-finite Gauge#set_range call outright" do
    s = nf_screen
    g = Widget::Gauge.new parent: s, top: 4, left: 0, width: 20, height: 1, value: 50
    g.set_range 0.0, Float64::NAN
    g.minimum.should eq 0.0
    g.maximum.should eq 100.0
    s.repaint
  end

  it "rejects a NaN GaugeList#maximum, keeping the previous bound, and renders" do
    s = nf_screen
    gl = Widget::GaugeList.new parent: s, top: 6, left: 0, width: 30, height: 4
    gl.add_item "cpu", 64
    gl.maximum = Float64::NAN
    gl.maximum.should eq 100.0
    s.repaint
  end

  it "rejects a non-finite Graph::Donut#set_range call outright" do
    s = nf_screen
    d = Widget::Graph::Donut.new parent: s, top: 0, left: 30, width: 18, height: 9,
      value: 50
    d.set_range 0.0, Float64::NAN
    d.minimum.should eq 0.0
    d.maximum.should eq 100.0
    s.repaint
  end
end

describe "BUGS16 B16-41: GaugeList::Item#value= sanitizes non-finite input" do
  it "coerces a NaN direct item.value= to the list's minimum and renders" do
    s = nf_screen
    gl = Widget::GaugeList.new parent: s, top: 0, left: 0, width: 30, height: 4
    gl.add_item "mem", 50
    gl["mem"].not_nil!.value = Float64::NAN
    gl["mem"].not_nil!.value.should eq gl.minimum
    s.repaint # must not raise OverflowError
  end

  it "coerces an Infinity direct item.value= to the list's minimum and renders" do
    s = nf_screen
    gl = Widget::GaugeList.new parent: s, top: 6, left: 0, width: 30, height: 4
    gl.add_item "net", 50
    gl["net"].not_nil!.value = Float64::INFINITY
    gl["net"].not_nil!.value.should eq gl.minimum
    s.repaint
  end
end
