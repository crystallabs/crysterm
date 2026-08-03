require "./spec_helper"

include Crysterm

# Regression: opening a bordered overlay/popup that shares (overlaps) a parent
# box's border one row below the parent's corner must not erase that corner cell.
#
# With `dock_borders`, the screen re-derives every line-drawing junction from its
# neighbors. Where a parent's right border continues past an overlapping child's
# top-left `┌` (child opens one row lower, sharing the column), the parent's
# top-right `┐` finds no down-neighbor "pointing back" — `Docking.angle_at`
# keeps a cell's own arm toward any present line neighbor, so the corner
# survives instead of being reduced to `─` while the overlay is up.
describe "border docking with an overlapping popup" do
  it "keeps the parent's top-right corner cell above the popup's shared edge" do
    s = headless_screen(40, 16, default_quit_keys: true)
    s.dock_borders = true

    # Parent bordered box: a line border on all sides.
    parent = Widget::Box.new(
      parent: s, top: 1, left: 1, width: 20, height: 12,
      style: Style.new(border: Border.new(type: BorderType::Solid)))

    # Overlay popup opened below-right of the parent's top-right corner: shares
    # the parent's right border column (`parent.xl - 1`) and starts one row below
    # the parent's top, so exactly one parent border cell (the `┐` corner) sits
    # directly above the popup's top edge.
    Widget::Box.new(
      parent: s, top: 2, left: 20, width: 16, height: 6,
      style: Style.new(border: Border.new(type: BorderType::Solid)))

    s.repaint

    plp = parent.last_rendered_position
    cx = plp.xl - 1 # the parent's right-border column
    cy = plp.yi     # the parent's top-border row (one row above the popup)

    # Must still be the top-right corner glyph (a box-drawing char with a
    # downward arm), not blanked or reduced to a bare horizontal rule.
    corner = s.lines[cy][cx].char
    corner.should eq '┐'

    # And it joins downward into the popup's shared-border junction.
    s.lines[cy + 1][cx].char.should eq '├'
  end
end
