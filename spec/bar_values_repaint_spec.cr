require "./spec_helper"

include Crysterm

# `Widget::Graph::Bar` rebuilds its glyph grid from `#values` in `#render`, but
# its `#values=` setter used to just store the new data and return — scheduling
# no repaint. Under the default `DamageTracking` optimization a widget is only
# repainted when it is registered in the screen's pending dirty-roots set, so a
# bare `bar.values = [...]` left the chart showing stale bars until some
# unrelated frame dirtied it. Its sibling `Widget::Graph::StackedBar#values=`
# already `mark_dirty`s on a data change; `Bar` now matches it.
#
# `mark_dirty` records the changed widget (via its top-level ancestor) in
# `@damage_dirty_roots`. The bar here is a direct screen child (the screen is not
# a `Widget`, so its `parent` is nil), so it is its own root. These specs render
# once, drain the damage set to a clean baseline, then assign new values with NO
# manual render and assert the bar got marked for repaint.
private def bvr_screen
  Crysterm::Screen.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false,
    optimization: Crysterm::OptimizationFlag::DamageTracking)
end

private def repaint_scheduled?(s : Crysterm::Screen, w : Crysterm::Widget)
  s.@damage_dirty_roots.includes? w
end

describe "Widget::Graph::Bar#values= schedules a repaint" do
  it "marks the bar dirty when assigned an integer array (the documented call)" do
    s = bvr_screen
    bar = Crysterm::Widget::Graph::Bar.new parent: s, top: 0, left: 0, width: 40, height: 8, max: 100.0
    s._render
    s.@damage_dirty_roots.clear
    repaint_scheduled?(s, bar).should be_false

    bar.values = [42, 88, 13, 64]
    bar.values.should eq [42.0, 88.0, 13.0, 64.0]
    repaint_scheduled?(s, bar).should be_true
  end

  it "marks the bar dirty when assigned a Float64 array (the generated-setter path)" do
    s = bvr_screen
    bar = Crysterm::Widget::Graph::Bar.new parent: s, top: 0, left: 0, width: 40, height: 8, max: 100.0
    s._render
    s.@damage_dirty_roots.clear
    repaint_scheduled?(s, bar).should be_false

    bar.values = [1.0, 2.0, 3.0]
    bar.values.should eq [1.0, 2.0, 3.0]
    repaint_scheduled?(s, bar).should be_true
  end
end
