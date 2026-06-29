require "./spec_helper"

include Crysterm

# `Widget::Pine::KeyMenu` lays its command hints out in a grid of `columns`
# columns across a (typically `width: "100%"`) bottom bar. The old layout gave
# each column a `100 // columns` *percentage* width and a `col * pct%` left,
# rounding every column independently. Whenever `columns` did not divide 100
# evenly (e.g. the default 6 → 16% each → 96% total) the columns drifted apart
# (a stray cell of gap between them) and the rightmost stopped short of the right
# edge, so the bar rendered with ragged gaps and a blank tail.
#
# The fix tiles the cells with integer division on the resolved width at render
# (`col * inner // n`), so consecutive columns share each boundary exactly: no
# gap between columns and the last column reaches the right edge for any
# `columns`/width combination.
#
# Driven headlessly over in-memory IOs: after one synchronous `_render` the cell
# boxes carry resolved absolute geometry to inspect.

private def km_screen(width = 80)
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: width,
    height: 24,
    default_quit_keys: false)
end

private def km_entries(n)
  (1..n).map { |i| Crysterm::Widget::Pine::KeyMenu::Entry.new(i.to_s, "Cmd#{i}") }
end

describe Crysterm::Widget::Pine::KeyMenu do
  it "tiles its columns across the full width with no gaps (columns not dividing 100)" do
    s = km_screen 80
    # 6 columns, one row: 100 // 6 == 16% each used to total only 96%.
    km = Crysterm::Widget::Pine::KeyMenu.new(
      parent: s, bottom: 0, left: 0, width: "100%",
      entries: km_entries(6), columns: 6, rows: 1)
    s._render

    cells = km.cells
    cells.size.should eq 6

    # The first column starts at the bar's (content) left edge.
    left_edge = km.aleft + km.ileft
    cells.first.aleft.should eq left_edge

    # Consecutive columns abut exactly — no stray gap (nor overlap) between them.
    (0...cells.size - 1).each do |i|
      cells[i + 1].aleft.should eq(cells[i].aleft + cells[i].awidth)
    end

    # The last column reaches the bar's (content) right edge — no ragged tail.
    right_edge = km.aleft + km.awidth - km.iright
    (cells.last.aleft + cells.last.awidth).should eq right_edge
  end

  it "still tiles exactly when the width does not divide evenly by columns" do
    s = km_screen 37 # 37 cells over 4 columns: not an even split
    km = Crysterm::Widget::Pine::KeyMenu.new(
      parent: s, bottom: 0, left: 0, width: "100%",
      entries: km_entries(8), columns: 4, rows: 2)
    s._render

    top_row = km.cells.select { |c| c.atop == km.cells.first.atop }
    top_row.size.should eq 4

    (0...top_row.size - 1).each do |i|
      top_row[i + 1].aleft.should eq(top_row[i].aleft + top_row[i].awidth)
    end
    right_edge = km.aleft + km.awidth - km.iright
    (top_row.last.aleft + top_row.last.awidth).should eq right_edge

    # Every column is at least one cell wide (no column collapsed to nothing).
    top_row.each(&.awidth.should(be > 0))
  end
end
