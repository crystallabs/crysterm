require "./spec_helper"

include Crysterm

# Regression spec for the BUGS4 ListTable fix: per-cell CSS recolor
# (`recolor_css_cells`) is keyed by *data-row* index (into `#rows`, header ==
# row 0), but the body scrolls by `@child_base`. It mapped the screen row
# straight to the data row, so once scrolled a row-specific rule
# (`Row:nth-child(N) Cell`) recolored the wrong screen row. Screen row `r >= 1`
# now maps to data row `r + @child_base` (screen row 0 is the pinned header).

private def lt_screen
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 30, height: 24)
end

private def cell_fg(screen, y, x)
  Crysterm::Attr.unpack_color(Crysterm::Attr.fg(screen.lines[y][x].attr))
end

# The content-relative rows (screen row minus the table's content top) that
# contain at least one cell painted *color*.
private def content_rows_with_fg(screen, lt, color) : Array(Int32)
  base = lt.atop + lt.itop
  ys = [] of Int32
  (0...screen.height).each do |y|
    next unless screen.lines[y]?
    if (0...screen.width).any? { |x| cell_fg(screen, y, x) == color }
      ys << y - base
    end
  end
  ys
end

describe "BUGS4 ListTable per-cell CSS recolor honors scroll (child_base)" do
  it "recolors the scrolled screen row of the targeted data row" do
    screen = lt_screen
    rows = [["H0", "H1"]]
    (1..14).each { |i| rows << ["r#{i}a", "r#{i}b"] }
    lt = Widget::ListTable.new parent: screen, top: 0, left: 0, width: 24, height: 10, rows: rows

    # `Row:nth-last-child(10)` == data row 5 (15 rows: 14 is last, 5 is the 10th
    # from the end). Counting from the end is robust to the item widgets that
    # precede the `<w-row>` nodes in the DOM; `nth-child(6)` does not reach the
    # body rows here.
    screen.stylesheet = "Row:nth-last-child(10) Cell { color: #ff0000; }"

    # Unscrolled: data row 5 shows at content row 5.
    screen._render
    content_rows_with_fg(screen, lt, 0xff0000).should contain(5)

    # Scrolled down by 3: data row 5 now shows at content row 2, NOT row 5. With
    # the pre-fix screen-row==data-row lookup, the styled-row check would miss
    # entirely (screen row 2 != data row 5), painting nothing.
    lt.child_base = 3
    screen._render
    reds = content_rows_with_fg(screen, lt, 0xff0000)
    reds.should contain(2)
    reds.should_not contain(5)
  end
end
