require "./spec_helper"

include Crysterm

# Regression spec for BUGS16 B16-07.

private def headless_screen(w = 80, h = 24, optimization = Crysterm::OptimizationFlag::None)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false, optimization: optimization)
end

# Compares two screens' cell buffers (attr + char + grapheme overlay), like
# `spec/damage_tracking_spec.cr`'s `assert_same_lines`.
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

# B16-07 — while `DamageTracking` was toggled OFF at runtime, every frame still
# ran `damage_full_composite`, but the per-subtree `damage_bounds` /
# `@damage_safe` / dims caches were only refreshed inside the tracking-enabled
# branch — and `@damage_force_full` (left false by the last tracked frame) was
# never re-armed by plain geometry changes. Re-enabling tracking then let the
# selective path engage against stale bounds: it cleared the widget's
# pre-off-period footprint instead of its actual one, leaving a ghost at the
# position the widget occupied while tracking was off.
describe "BUGS16 B16-07: re-enabling DamageTracking after an off period" do
  it "forces a full frame first, so no ghost survives at the off-period position" do
    plain = headless_screen w: 30, h: 8
    dmg = headless_screen w: 30, h: 8, optimization: Crysterm::OptimizationFlag::DamageTracking

    boxes = {plain, dmg}.map do |s|
      Widget::Box.new parent: s, top: 0, left: 0, width: 5, height: 2, content: "AA"
    end

    plain.repaint
    dmg.repaint
    dmg.damage_full_frames.should be > 0 # first frame is always full
    assert_same_lines dmg, plain, "initial"

    # Turn tracking off and move the widget A -> B: full composites keep the
    # buffer right, but the damage caches are now frozen at position A.
    dmg.optimization = Crysterm::OptimizationFlag::None
    boxes.each(&.left=(10))
    plain.repaint
    dmg.repaint
    assert_same_lines dmg, plain, "while tracking off"

    # Re-enable tracking and move B -> C. Pre-fix the selective path engaged
    # (force_full false, dims matching, stale @damage_safe) and cleared the
    # STALE bounds (A), leaving the widget's image at B as a ghost.
    dmg.optimization = Crysterm::OptimizationFlag::DamageTracking
    boxes.each(&.left=(20))
    plain.repaint
    full_before = dmg.damage_full_frames
    dmg.repaint
    # The first frame after re-enabling must run full (refreshing all caches)…
    dmg.damage_full_frames.should eq full_before + 1
    # …and the buffer must match a screen that never tracked damage: in
    # particular, no "AA" ghost at columns 10-14.
    assert_same_lines dmg, plain, "after re-enable"
  end
end
