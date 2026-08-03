require "./spec_helper"

include Crysterm

# O5-14 — `Layout::Grid#arrange` walks the child list twice on purpose: every
# `Grid::Hint` must claim its cells before any auto-flow child looks for a free
# one, *regardless of where the hinted children sit in the child list*. That
# ordering is the constraint any single-pass rewrite of the two walks has to
# keep (a merge that placed hint-less children on sight would hand a cell to an
# auto child that a later-declared hint owns), and no existing Grid spec pins
# it: they all declare their hints first. These interleave the two kinds.

describe "OPT5 O5-14: Grid auto-flow respects hints regardless of child order" do
  it "skips a hinted cell claimed by a child declared after the auto ones" do
    s = headless_screen(80, 24)
    g = Widget::Box.new parent: s, left: 0, top: 0, width: 30, height: 5,
      layout: Layout::Grid.new(columns: 3, rows: 1)
    a = Widget::Box.new parent: g
    b = Widget::Box.new parent: g
    h = Widget::Box.new parent: g,
      layout_hint: Layout::Grid::Hint.new(row: 0, column: 1)

    s.repaint

    gl = g.lpos.not_nil!
    # The hint owns the middle cell; the two auto children flow around it, in
    # child order — not into it, and not shifted by one.
    h.lpos.not_nil!.xi.should eq gl.xi + 10
    a.lpos.not_nil!.xi.should eq gl.xi
    b.lpos.not_nil!.xi.should eq gl.xi + 20
  ensure
    s.try &.destroy
  end

  it "keeps the auto-flow cursor in child order across interleaved hints" do
    s = headless_screen(80, 24)
    g = Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 10,
      layout: Layout::Grid.new(columns: 2)
    a = Widget::Box.new parent: g
    h = Widget::Box.new parent: g,
      layout_hint: Layout::Grid::Hint.new(row: 0, column: 0)
    b = Widget::Box.new parent: g

    s.repaint

    gl = g.lpos.not_nil!
    # 2 columns x 2 inferred rows over 20x10: cells are 10 wide, 5 tall.
    hl = h.lpos.not_nil!
    {hl.xi, hl.yi}.should eq({gl.xi, gl.yi})
    al = a.lpos.not_nil!
    {al.xi, al.yi}.should eq({gl.xi + 10, gl.yi}) # first free cell (0,1)
    bl = b.lpos.not_nil!
    {bl.xi, bl.yi}.should eq({gl.xi, gl.yi + 5}) # then (1,0)
  ensure
    s.try &.destroy
  end
end
