require "./spec_helper"

include Crysterm

# `Widget::Graph::Bar#values=` used to store new data without scheduling a
# repaint, so under `DamageTracking` a bare `bar.values = [...]` left stale
# bars until an unrelated frame dirtied it. Sibling `StackedBar#values=`
# already calls `mark_dirty`; `Bar` now matches it.
#
# `mark_dirty` records the widget (via its top-level ancestor) in
# `@damage_dirty_roots`; the bar here is a direct screen child so it's its own
# root. Specs render once, drain the damage set, then assign values with no
# manual render and assert the bar got marked dirty.
private def bvr_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false,
    optimization: Crysterm::OptimizationFlag::DamageTracking)
end

private def repaint_scheduled?(s : Crysterm::Window, w : Crysterm::Widget)
  s.@damage_dirty_roots.includes? w
end

describe "Widget::Graph::Bar#values= schedules a repaint" do
  it "marks the bar dirty when assigned an integer array (the documented call)" do
    s = bvr_screen
    bar = Crysterm::Widget::Graph::Bar.new parent: s, top: 0, left: 0, width: 40, height: 8, maximum: 100.0
    s.repaint
    s.@damage_dirty_roots.clear
    repaint_scheduled?(s, bar).should be_false

    bar.values = [42, 88, 13, 64]
    bar.values.should eq [42.0, 88.0, 13.0, 64.0]
    repaint_scheduled?(s, bar).should be_true
  end

  it "marks the bar dirty when assigned a Float64 array (the generated-setter path)" do
    s = bvr_screen
    bar = Crysterm::Widget::Graph::Bar.new parent: s, top: 0, left: 0, width: 40, height: 8, maximum: 100.0
    s.repaint
    s.@damage_dirty_roots.clear
    repaint_scheduled?(s, bar).should be_false

    bar.values = [1.0, 2.0, 3.0]
    bar.values.should eq [1.0, 2.0, 3.0]
    repaint_scheduled?(s, bar).should be_true
  end
end
