require "./spec_helper"

include Crysterm

# Regression: opening a bordered overlay/popup that shares (overlaps) a parent
# box's border one row BELOW the parent's corner must not erase that corner cell.
#
# With `dock_borders`, the screen re-derives every line-drawing junction from its
# neighbors. Where a parent box's right border continues *past* an overlapping
# child's top-left `┌` (the child opens one row lower and shares the column), the
# parent's top-right `┐` finds no down-neighbor that "points back" and used to be
# reduced to `─` — dropping the corner while the overlay was up (it reappeared on
# close). `Docking.angle_at` now keeps a cell's own arm toward any present line
# neighbor, so the corner survives.
private def sized_screen(w, h)
  Crysterm::Screen.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h)
end

describe "border docking with an overlapping popup" do
  it "keeps the parent's top-right corner cell above the popup's shared edge" do
    s = sized_screen 40, 16
    s.dock_borders = true

    # Parent bordered box: a line border on all sides.
    parent = Widget::Box.new(
      parent: s, top: 1, left: 1, width: 20, height: 12,
      style: Style.new(border: Border.new(type: BorderType::Line)))

    # Overlay popup opened below-right of the parent's top-right corner: it shares
    # the parent's right border column (`parent.xl - 1`) and starts ONE ROW below
    # the parent's top, so exactly one parent border cell (the `┐` corner) sits
    # directly above the popup's top edge.
    Widget::Box.new(
      parent: s, top: 2, left: 20, width: 16, height: 6,
      style: Style.new(border: Border.new(type: BorderType::Line)))

    s._render

    plp = parent.last_rendered_position
    cx = plp.xl - 1 # the parent's right-border column
    cy = plp.yi     # the parent's top-border row (one row above the popup)

    # That cell must still be the top-right corner glyph (a box-drawing char with
    # a downward arm), not blanked or reduced to a bare horizontal rule.
    corner = s.lines[cy][cx].char
    corner.should eq '┐'

    # And it joins downward into the popup's shared-border junction.
    s.lines[cy + 1][cx].char.should eq '├'
  end
end
