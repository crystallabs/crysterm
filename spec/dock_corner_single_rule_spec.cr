require "./spec_helper"

include Crysterm

# Regression: a box-drawing CORNER with a perpendicular rule touching only one
# of its two arms (and nothing reciprocating) must keep its corner glyph, not
# be reduced to a straight stroke.
#
# `Docking.angle_at` preserves a cell's own arm toward any present line
# neighbor (so an overlapped corner survives — see `dock_overlap_corner_spec`),
# but that must only AUGMENT a genuine junction. When no neighbor reciprocates,
# the cell connects to nothing and must keep its own glyph. Without the
# no-reciprocation guard, a `┌` with a `─` directly below it (which doesn't
# open upward) resolved to the single-arm `│`, severing the corner.
private def grid(rows : Array(String), attr : Int64 = 0_i64) : Array(Crysterm::Window::Row)
  rows.map do |s|
    row = Crysterm::Window::Row.new
    s.each_char { |c| row.push attr, c }
    row
  end
end

describe "Docking.angle_at corner with a single non-reciprocating rule" do
  it "keeps a corner whose lone perpendicular neighbor does not point back" do
    # `┌` (right + down arms) over a `─` (left + right arms): the `─` has no
    # upward arm so it does not reciprocate, and the right arm faces blank.
    # Nothing connects, so the `┌` must be preserved.
    Docking.angle_at(grid(["┌", "─"]), 0, 0, DockContrast::Ignore).should eq '┌'
    # Symmetric cases for the other three corners against a single rule.
    Docking.angle_at(grid(["─", "└"]), 0, 1, DockContrast::Ignore).should eq '└'
    Docking.angle_at(grid([" ┐", " ─"]), 1, 0, DockContrast::Ignore).should eq '┐'
    Docking.angle_at(grid([" ─", " ┘"]), 1, 1, DockContrast::Ignore).should eq '┘'
  end

  it "still docks a corner whose arms genuinely connect" do
    # Sanity: unchanged when the arms genuinely reciprocate.
    Docking.angle_at(grid(["┌─", "│ "]), 0, 0, DockContrast::Ignore).should eq '┌'
  end
end
