require "./spec_helper"

include Crysterm

# Regression specs for BUGS16 B16-10 and B16-11.

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

# B16-10 — `overflow=` did not `mark_dirty`, so a runtime overflow-policy
# change never scheduled a repaint. Under `OptimizationFlag::DamageTracking`
# this is observable: since the widget is never added to the dirty-roots set,
# a later selective frame skips its subtree entirely and the newly-imposed
# `Hidden` clip never paints, even though a plain (non-damage) screen with the
# identical mutation clips immediately.
describe "BUGS16 B16-10: overflow= marks the widget dirty" do
  it "clips an overflowing child on the very next selective (damage-tracking) frame" do
    plain = headless_screen w: 30, h: 6
    dmg = headless_screen w: 30, h: 6, optimization: Crysterm::OptimizationFlag::DamageTracking

    {plain, dmg}.each do |s|
      container = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
      # Child spills past the container's right edge; with `overflow: Ignore`
      # (the default) it paints unclipped onto the screen.
      Widget::Box.new parent: container, top: 0, left: 0, width: 20, height: 1,
        content: "x" * 20
    end

    plain._render
    dmg._render
    dmg.damage_full_frames.should be > 0 # first frame is always full

    assert_same_lines dmg, plain, "before overflow="

    # Isolate the setter under test: no other mutation happens between the two
    # renders, so only `overflow=`'s own dirtying (or lack of it) can bring the
    # subtree back into the selective frame's dirty set.
    plain.children.first.overflow = Overflow::Hidden
    dmg.children.first.overflow = Overflow::Hidden

    plain._render
    dmg._render

    # Pre-fix: the damage-tracking screen's clip never engages (the widget's
    # subtree was skipped), so its cells still show the un-clipped "xxxx...x"
    # spilling past column 10, while the plain screen already clips it.
    assert_same_lines dmg, plain, "after overflow="
  end
end

# B16-11 — two defects in the scroll-index clamp wiring (see BUGS16.md).
describe "BUGS16 B16-11: scrollable= re-enable reclamps immediately" do
  it "reclamps child_base on re-enable after a shrink while disabled" do
    s = headless_screen
    box = Widget::Box.new parent: s, width: 10, height: 5, scrollable: true

    box.set_content(Array.new(20) { |i| "line #{i}" }.join("\n"))
    box.scroll(15)
    box.child_base.should be > 0 # scrolled down into the content

    # B16-15 (wave 3): disabling now resets the scroll state outright, since
    # no repair path is reachable while non-scrollable. The re-enable reclamp
    # (this finding) remains load-bearing for any path that leaves child_base
    # stale relative to shrunken content — pin it by scrolling again through
    # the widget's own API after re-enabling.
    box.scrollable = false
    box.child_base.should eq 0 # reset on disable (B16-15)
    box.set_content("one line")

    box.scrollable = true # re-enable: must reclamp immediately
    box.child_base.should eq 0
    box.scroll(15)
    box.child_base.should eq 0 # 1-line content: nothing to scroll to
  end

  it "wires the ContentParsed handler exactly once for a constructor-scrollable widget toggled off/on" do
    s = headless_screen
    box = Widget::Box.new parent: s, width: 10, height: 5, scrollable: true
    n = box.handlers(Crysterm::Event::ContentParsed).size
    n.should be > 0

    box.scrollable = false
    box.scrollable = true
    box.handlers(Crysterm::Event::ContentParsed).size.should eq n
  end
end
