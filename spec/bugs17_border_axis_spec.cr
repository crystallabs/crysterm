require "./spec_helper"

include Crysterm

# Regression specs for BUGS17 B17-08: Layout::Border kept raw/assigned
# bookkeeping for only the CONSUME axis (@consume_raw/@consume_assigned).
# Placing a child also overwrites its SPAN axis with a resolved Int32, with
# no bookkeeping at all -- so re-docking a child to a perpendicular region
# (top/bottom <-> left/right) read the OTHER axis's stale resolved value as
# if it were the new consume axis's raw size, poisoning it (e.g. a 30-wide
# panel re-docked from :top to :left would swallow the full interior width).
# The fix keys bookkeeping by axis (@raw_width/@assigned_width,
# @raw_height/@assigned_height), restored and recorded for every managed
# child -- edges and center alike -- every frame.

private def headless_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

describe "BUGS17 Border axis-keyed bookkeeping (fix B17-08)" do
  it "recovers a re-docked child's explicit consume-axis size instead of a stale full-span value" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 80, height: 24,
      layout: Layout::Border.new
    panel = Widget::Box.new parent: box, width: 30, height: 3,
      layout_hint: Layout::Border::Hint.new(:top)
    Widget::Box.new parent: box # center

    s.repaint
    # Frame 1: docked :top, width is the span axis -- spans the full interior
    # regardless of the explicit 30.
    pl = panel.lpos.not_nil!
    (pl.xl - pl.xi).should eq 80

    # Re-dock to :left: width becomes the consume axis. Pre-fix, the single
    # consume map compared the old (height) assigned value against the new
    # raw width read (the poisoned 80 written during the :top frame), always
    # mismatched, and adopted 80 as the child's "raw" width -- swallowing the
    # whole interior. Fixed: the explicit 30 resurfaces.
    panel.layout_hint = Layout::Border::Hint.new(:left)
    s.repaint
    pl2 = panel.lpos.not_nil!
    (pl2.xl - pl2.xi).should eq 30
  end

  it "round-trips :top -> :left -> :top, restoring the original raw height" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 80, height: 24,
      layout: Layout::Border.new
    panel = Widget::Box.new parent: box, width: 30, height: 3,
      layout_hint: Layout::Border::Hint.new(:top)
    Widget::Box.new parent: box # center

    s.repaint
    pl = panel.lpos.not_nil!
    (pl.yl - pl.yi).should eq 3

    panel.layout_hint = Layout::Border::Hint.new(:left)
    s.repaint
    pl2 = panel.lpos.not_nil!
    (pl2.yl - pl2.yi).should eq 24 # height is now the span axis: full remaining height

    panel.layout_hint = Layout::Border::Hint.new(:top)
    s.repaint
    pl3 = panel.lpos.not_nil!
    (pl3.yl - pl3.yi).should eq 3 # original raw height recovered, not the stale 24 span
  end

  it "leaves a plain single-region layout unchanged (sizes/positions pinned)" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 80, height: 24,
      layout: Layout::Border.new
    header = Widget::Box.new parent: box, height: 2,
      layout_hint: Layout::Border::Hint.new(:top)
    sidebar = Widget::Box.new parent: box, width: 20,
      layout_hint: Layout::Border::Hint.new(:left)
    center = Widget::Box.new parent: box

    s.repaint
    s.repaint # second frame: the matched-raw restore path must be a no-op

    hl = header.lpos.not_nil!
    sl = sidebar.lpos.not_nil!
    cl = center.lpos.not_nil!

    hl.xi.should eq 0
    hl.xl.should eq 80
    hl.yi.should eq 0
    hl.yl.should eq 2

    sl.xi.should eq 0
    sl.xl.should eq 20
    sl.yi.should eq 2
    sl.yl.should eq 24

    cl.xi.should eq 20
    cl.xl.should eq 80
    cl.yi.should eq 2
    cl.yl.should eq 24
  end
end
