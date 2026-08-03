require "./spec_helper"

include Crysterm

# `Widget::Gauge#segments=` must both bump `@segments_version` (so the *next*
# render rebuilds the cached content) and schedule that render via
# `request_render`, matching its sibling `#value=` (and `Bar#values=` /
# `GaugeList`'s data setters) — bumping alone leaves the previous stacked bars
# on window under `DamageTracking` until an unrelated frame happens to repaint.
#
# `request_render` records the widget (mapped to its top-level ancestor) in
# `@damage_dirty_roots` and rings the render doorbell (async, no synchronous
# drain). The gauge here is a direct screen child, so it is its own root. The
# spec renders once, drains the damage set, then assigns segments with no manual
# render and asserts the gauge got marked dirty.

private def gsr_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false,
    optimization: Crysterm::OptimizationFlag::DamageTracking)
end

describe "Widget::Gauge#segments= schedules a repaint" do
  it "marks the gauge dirty when the stacked segments are replaced" do
    s = gsr_screen
    gauge = Crysterm::Widget::Gauge.new parent: s, top: 0, left: 0, width: 20, height: 1,
      segments: [Crysterm::Widget::Gauge::Segment.new(100, "green")]
    s.repaint
    s.@damage_dirty_roots.clear
    s.@damage_dirty_roots.includes?(gauge).should be_false

    gauge.segments = [Crysterm::Widget::Gauge::Segment.new(100, "red")]

    s.@damage_dirty_roots.includes?(gauge).should be_true
  end
end
