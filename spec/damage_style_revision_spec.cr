require "./spec_helper"

include Crysterm

private def headless_screen(w = 30, h = 8, optimization = Crysterm::OptimizationFlag::None)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false, optimization: optimization)
end

# Compares two screens' cell buffers, like `spec/damage_tracking_spec.cr`.
private def assert_same_lines(a : Crysterm::Window, b : Crysterm::Window, ctx = "")
  a.cell_rows.size.should eq b.cell_rows.size
  a.cell_rows.each_index do |y|
    la = a.cell_rows[y]
    lb = b.cell_rows[y]
    la.size.should eq lb.size
    la.size.times do |x|
      ca = la[x]
      cb = lb[x]
      if ca.attr != cb.attr || ca.char != cb.char
        fail "cell mismatch at (#{y},#{x}) #{ctx}: " \
             "full=(attr=#{cb.attr},char=#{cb.char.inspect}) " \
             "damage=(attr=#{ca.attr},char=#{ca.char.inspect})"
      end
    end
  end
end

# An in-place mutation of a style's attribute fields (`style.bg = ...`) fires
# no tracked setter. Damage tracking now observes it through the per-frame
# `Style#attr_revision` sweep (`Window#damage_sweep_style_revisions`), so the
# next frame repaints the widget — previously the selective path saw no dirty
# root and carried the stale cells forward, and the documented workaround was
# a window-wide `OptimizationFlag::None`.
describe "damage tracking observes in-place style mutation (attr_revision sweep)" do
  it "repaints a widget whose style was mutated in place, matching the full path" do
    plain = headless_screen
    dmg = headless_screen optimization: Crysterm::OptimizationFlag::DamageTracking

    boxes = {plain, dmg}.map do |s|
      Widget::Box.new parent: s, top: 1, left: 2, width: 8, height: 3,
        content: "hi", style: Style.new(fg: "white", bg: "blue")
    end

    plain.repaint
    dmg.repaint
    assert_same_lines dmg, plain, "initial"

    # A no-change frame settles the damage path into its selective steady state.
    plain.repaint
    dmg.repaint
    before = dmg.cell_rows[2][3].attr

    # The in-place mutation, with no `update` and no tracked setter — the
    # persistent per-state style is what rendering derives from.
    boxes.each(&.state_style.bg=("red"))
    plain.repaint
    dmg.repaint

    # The change must actually land (guards against a trivially-equal pass) …
    dmg.cell_rows[2][3].attr.should_not eq before
    # … and the damage-tracked buffer must match the always-full one.
    assert_same_lines dmg, plain, "after in-place style.bg mutation"
  end

  it "still takes the fast no-op path when nothing changed" do
    dmg = headless_screen optimization: Crysterm::OptimizationFlag::DamageTracking
    Widget::Box.new parent: dmg, top: 1, left: 2, width: 8, height: 3,
      content: "hi", style: Style.new(fg: "white", bg: "blue")

    dmg.repaint
    dmg.repaint # settle
    fast_before = dmg.damage_fast_frames
    dmg.repaint # nothing changed since the settle frame
    dmg.damage_fast_frames.should be > fast_before
  end
end
