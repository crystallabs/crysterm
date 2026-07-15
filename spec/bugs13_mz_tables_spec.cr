require "./spec_helper"

include Crysterm

# BUGS13 M-Z table cluster regression coverage:
#   M3  — Table#draw_borders must not wrap negative buffer indices (table
#         partly above/left of the screen) and must not stamp its top junction
#         row one row ABOVE the widget when border-top is 0; ListTable: same
#         for its bottom junction row when border-bottom is 0.
#   W14 — vertical separators / junction columns must clip against the content
#         width (`width - ileft`), not stamp one column outside the widget.
#   A9  — ListTable#sortable is honored when toggled at runtime, both ways.
#   A18 — set_data([]) must clear the view along with the model.

private def tbl_screen(width = 30, height = 12)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height)
end

private def row_chars(s, y)
  String.build do |io|
    s.lines[y].each { |cell| io << cell.char }
  end
end

private def mouse_down(x : Int32, y : Int32)
  Crysterm::Event::Mouse.new(
    Tput::Mouse::Event.new(Tput::Mouse::Action::Down, Tput::Mouse::Button::Left, x, y))
end

describe "BUGS13 M3: Table#draw_borders row/column clamping" do
  it "does not stamp a junction row above the widget when border-top is 0" do
    s = tbl_screen
    Widget::Table.new(parent: s, top: 3, left: 2,
      rows: [["Name", "Email"], ["a", "b"]],
      style: Style.new(border: Border.new(top: 0)))
    s._render
    # The row just above the table (y == 2) must stay untouched; the bug
    # stamped `│` at `yi + border.top - 1 == yi - 1` when border-top was 0.
    row_chars(s, 2).strip.should eq ""
  ensure
    s.try &.destroy
  end

  it "does not wrap junction/run rows to the bottom of the screen for a table scrolled above it" do
    s = tbl_screen
    Widget::Table.new(parent: s, top: -3, left: 0,
      rows: [["Name", "Email"], ["a", "b"], ["c", "d"]],
      style: Style.new(border: true))
    s._render
    # Grid rows -3..-1 used to wrap (`lines[-3]?` == `lines[9]`) and stamp
    # border glyphs onto the bottom rows of the screen buffer.
    (9..11).each do |y|
      row_chars(s, y).strip.should eq ""
    end
  ensure
    s.try &.destroy
  end
end

describe "BUGS13 W14 + M3: ListTable#draw_borders clipping" do
  it "clips junctions/separators to the content edge (no stamp one column outside)" do
    s = tbl_screen(20, 8)
    Widget::ListTable.new(parent: s, top: 0, left: 0, width: 8, height: 6,
      rows: [["Hdr01", "Hdr02"], ["abcde", "fghij"], ["klmno", "pqrst"]],
      style: Style.new(border: Border.new(right: 0)))
    s._render
    # Columns are wider than the 8-cell viewport; the first separator falls at
    # content offset 7, which the off-by-`ileft` clip used to paint at
    # absolute column 8 — one column OUTSIDE the widget (columns 0..7).
    (0...6).each do |y|
      s.lines[y][8].char.should eq ' '
    end
  ensure
    s.try &.destroy
  end

  it "does not stamp junctions one row below a table with border-bottom: 0" do
    s = tbl_screen(20, 10)
    Widget::ListTable.new(parent: s, top: 0, left: 0, height: 5,
      rows: [["AA", "BB"], ["a", "b"], ["c", "d"]],
      style: Style.new(border: Border.new(bottom: 0)))
    s._render
    # With no bottom border, the `ry == height` junction row is
    # `yl - ibottom == yl` — the row just BELOW the widget (rows 0..4).
    row_chars(s, 5).strip.should eq ""
  ensure
    s.try &.destroy
  end
end

describe "BUGS13 A9: ListTable runtime sortable toggle" do
  it "honors sortable enabled and disabled after construction" do
    s = tbl_screen(30, 10)
    lt = Widget::ListTable.new(parent: s, top: 0, left: 0,
      rows: [["N", "V"], ["b", "2"], ["a", "1"]])
    s._render

    # Disabled (the default): a header click must not sort.
    lt.header.emit Crysterm::Event::Mouse, mouse_down(lt.header.aleft, lt.header.atop).mouse
    lt.sort_column.should be_nil

    # Enabled at runtime: the same click sorts by the clicked column.
    lt.sortable = true
    lt.header.emit Crysterm::Event::Mouse, mouse_down(lt.header.aleft, lt.header.atop).mouse
    lt.sort_column.should eq 0
    lt.rows[1][0].should eq "a"

    # Disabled again: the active sort is forgotten and clicks are inert.
    lt.sortable = false
    lt.sort_column.should be_nil
    lt.header.emit Crysterm::Event::Mouse, mouse_down(lt.header.aleft, lt.header.atop).mouse
    lt.sort_column.should be_nil
  ensure
    s.try &.destroy
  end
end

describe "BUGS13 A18: set_data([]) clears the view along with the model" do
  it "ListTable: empties items and header" do
    s = tbl_screen(30, 10)
    lt = Widget::ListTable.new(parent: s, top: 0, left: 0,
      rows: [["N", "V"], ["b", "2"], ["a", "1"]])
    lt.items.size.should eq 3 # header spacer + 2 body rows

    lt.rows = [] of Array(String)
    lt.rows.should be_empty
    lt.items.size.should eq 1 # just the header spacer
    lt.header.rendered_content.strip.should eq ""
  ensure
    s.try &.destroy
  end

  it "ListTable: constructing without rows stays item-less" do
    s = tbl_screen(30, 10)
    lt = Widget::ListTable.new(parent: s, top: 0, left: 0)
    lt.items.size.should eq 0
    lt.rows = [] of Array(String)
    lt.items.size.should eq 0
  ensure
    s.try &.destroy
  end

  it "Table: clears the rendered content" do
    s = tbl_screen(30, 10)
    t = Widget::Table.new(parent: s, top: 0, left: 0,
      rows: [["N", "V"], ["a", "1"]])
    t.rows = [] of Array(String)
    t.rows.should be_empty
    t.rendered_content.strip.should eq ""
  ensure
    s.try &.destroy
  end
end
