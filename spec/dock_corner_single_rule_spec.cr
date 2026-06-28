require "./spec_helper"

include Crysterm

# Regression: a box-drawing CORNER that has a perpendicular rule touching only
# one of its two arms (and nothing reciprocating) must keep its corner glyph, not
# be reduced to a straight stroke.
#
# `Docking.angle_at` preserves a cell's own arm toward any present line neighbor
# (so an overlapped corner survives — see `dock_overlap_corner_spec`). But that
# self-preservation must only AUGMENT a genuine junction. When NO neighbor
# reciprocates (points back), the cell connects to nothing and must keep its own
# glyph. Without the no-reciprocation guard, a `┌` with a `─` directly below it
# (the `─` does not open upward, so it never connects to the `┌`) resolved to the
# single-arm `│` — severing the corner the preservation pass is meant to protect.
private def grid(rows : Array(String), attr : Int64 = 0_i64) : Array(Crysterm::Screen::Row)
  rows.map do |s|
    row = Crysterm::Screen::Row.new
    s.each_char { |c| row.push attr, c }
    row
  end
end

describe "Docking.angle_at corner with a single non-reciprocating rule" do
  it "keeps a corner whose lone perpendicular neighbor does not point back" do
    # `┌` (right + down arms) over a `─` (left + right arms): the `─` sits in the
    # down direction but has no upward arm, so it does NOT reciprocate, and the
    # right arm faces blank. Nothing connects, so the `┌` must be preserved.
    Docking.angle_at(grid(["┌", "─"]), 0, 0, DockContrast::Ignore).should eq '┌'
    # Symmetric cases for the other three corners against a single rule.
    Docking.angle_at(grid(["─", "└"]), 0, 1, DockContrast::Ignore).should eq '└'
    Docking.angle_at(grid([" ┐", " ─"]), 1, 0, DockContrast::Ignore).should eq '┐'
    Docking.angle_at(grid([" ─", " ┘"]), 1, 1, DockContrast::Ignore).should eq '┘'
  end

  it "still docks a corner whose arms genuinely connect" do
    # Sanity: a `┌` whose right (`─`) and down (`│`) neighbors both reciprocate
    # is unchanged (the guard only fires when nothing connects).
    Docking.angle_at(grid(["┌─", "│ "]), 0, 0, DockContrast::Ignore).should eq '┌'
  end
end
