require "./spec_helper"

include Crysterm

# Differential test for the latched-full bookkeeping shed (the `need_bounds`
# gating in `Window#damage_full_composite`): while the EMA latch holds the
# selective path off, full frames skip the O(all widgets) bounds refresh, and
# only the frame right before a re-probe refreshes it. A re-probe attempt
# therefore runs against bounds refreshed exactly one frame earlier — the same
# one-frame-old contract continuous selective operation relies on.
#
# This drives a scene degenerate → mostly-static → degenerate across a full
# re-probe window, asserting the damage screen's cell buffer stays identical to
# a plain full-recomposite screen on every frame — including the re-probe frame
# that succeeds on skipped-then-refreshed bounds, the path the gating's
# correctness argument hinges on.

private def new_screen(damage : Bool)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 60, height: 24,
    optimization: damage ? Crysterm::OptimizationFlag::DamageTracking : Crysterm::OptimizationFlag::None)
end

# Asserts the two screens' cell buffers are identical.
private def assert_same_lines(a : Crysterm::Window, b : Crysterm::Window, ctx = "")
  a.lines.size.should eq b.lines.size
  a.lines.each_index do |y|
    la = a.lines[y]
    lb = b.lines[y]
    la.size.should eq lb.size
    la.size.times do |x|
      ca = la[x]
      cb = lb[x]
      if ca.attr != cb.attr || ca.char != cb.char || la.grapheme_at?(x) != lb.grapheme_at?(x)
        fail "cell mismatch at (#{y},#{x}) #{ctx}: " \
             "full=(attr=#{cb.attr},char=#{cb.char.inspect},g=#{lb.grapheme_at?(x).inspect}) " \
             "damage=(attr=#{ca.attr},char=#{ca.char.inspect},g=#{la.grapheme_at?(x).inspect})"
      end
    end
  end
end

# Four tiles covering the whole screen plus a small box that slides over them.
# With every subtree dirty, `2 * Σ dirty-area >= full_cost` holds, so the
# degenerate phase trips the deterministic cost-parity bail (no timing
# dependence) and latches selective off.
private def build_scene(screen)
  tiles = [] of Widget::Box
  4.times do |i|
    tiles << Widget::Box.new(parent: screen,
      top: (i // 2) * 12, left: (i % 2) * 30, width: 30, height: 12,
      content: "tile #{i}")
  end
  mover = Widget::Box.new(parent: screen, top: 5, left: 0, width: 6, height: 3,
    content: "mv")
  {tiles, mover}
end

# Every subtree changes: all tiles restyle their content and the mover moves.
private def mutate_degenerate(tiles, mover, f)
  tiles.each_with_index { |t, i| t.content = "tile #{i} f#{f}" }
  mover.content = "m#{f % 10}"
  mover.left = f % 50
end

# Mostly static: only the mover slides (overlapping tiles, so a re-probe
# attempt exercises the cluster recomposite), plus an occasional tile update.
private def mutate_static(tiles, mover, f)
  mover.left = f % 50
  tiles[0].content = "tile 0 f#{f}" if f % 7 == 0
end

describe "damage tracking re-probe across the latched window" do
  it "stays output-identical through degenerate → static → degenerate transitions" do
    plain = new_screen false
    dmg = new_screen true
    pt, pm = build_scene plain
    dt, dm = build_scene dmg

    plain.repaint
    dmg.repaint
    assert_same_lines dmg, plain, "(initial)"

    f = 0
    step = ->(degenerate : Bool) do
      if degenerate
        mutate_degenerate pt, pm, f
        mutate_degenerate dt, dm, f
      else
        mutate_static pt, pm, f
        mutate_static dt, dm, f
      end
      plain.repaint
      dmg.repaint
      assert_same_lines dmg, plain, "(frame #{f})"
      f += 1
    end

    # Degenerate: the first attempt trips the cost-parity bail, falls back, and
    # latches selective off; subsequent full frames skip the bounds refresh.
    20.times { step.call true }
    dmg.damage_fast_frames.should eq 0

    # Mostly-static through the rest of the latched window and across the
    # re-probe: the attempt runs on bounds refreshed exactly one frame before
    # it, succeeds, and selective resumes.
    (Crysterm::Window::DAMAGE_REPROBE_FRAMES + 10).times { step.call false }
    dmg.damage_fast_frames.should be > 0

    # Back to degenerate: the parity bail re-latches; output stays identical.
    15.times { step.call true }
  end
end
