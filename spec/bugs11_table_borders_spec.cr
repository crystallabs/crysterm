require "./spec_helper"

include Crysterm

private def hwindow(w = 60, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

# Reads the rendered characters of screen row *y* across the table's interior
# columns [xi, xl).
private def row_chars(s, lp, y)
  (lp.xi...lp.xl).map { |x| s.lines[y][x]?.try(&.char) || ' ' }.join
end

# Horizontal-rule and junction glyphs that must never overwrite a cell's text
# row (the internal `│` separator is legitimate on a text row, so it's excluded).
private HRULE_GLYPHS = "─┼┬┴├┤"
# Any gridline glyph — used to prove none leak outside the visible rectangle.
private GRID_GLYPHS = "─│┬┴├┤┼┌┐└┘"

# BUGS11 #20 — `Table#draw_borders` hardcoded a vertical top inset of 1, so any
# vertical padding shifted the real content rows down while the gridline grid
# stayed put: the `─` fills and `┼`/`├`/`┤`/`┴` junctions landed on the cell
# text rows and destroyed the text. The fix addresses the internal grid relative
# to the real content origin (`itop`), keeping the outer `┬`/`┴` rows on the
# actual top/bottom border rows.
describe "BUGS11 #20 Table#draw_borders honors vertical padding" do
  it "does not paint gridlines over padded cell text" do
    s = hwindow
    s.alloc
    t = Crysterm::Widget::Table.new(parent: s, left: 0, top: 0,
      rows: [["Name", "Email"], ["Alice", "a@x"]],
      style: Crysterm::Style.new(border: true, padding: Padding.new(0, 1, 0, 1)))
    s.repaint

    lp = t.lpos.not_nil!
    t.itop.should eq 2 # border.top (1) + padding.top (1): the shifted origin

    header_row = lp.yi + t.itop # content row 0 (header)
    sep_row = header_row + 1    # blank separator row between header and body
    body_row = header_row + 2   # content row 1 (first body row)

    htext = row_chars s, lp, header_row
    btext = row_chars s, lp, body_row

    # The cell text survives — before the fix these rows were overwritten with
    # `─`/`┼` gridlines and the words vanished.
    htext.should contain("Name")
    htext.should contain("Email")
    btext.should contain("Alice")

    # ...and no horizontal-rule / junction glyph is stamped onto the text rows.
    HRULE_GLYPHS.each_char do |g|
      htext.includes?(g).should be_false
      btext.includes?(g).should be_false
    end

    # The internal junction row lands on the (blank) separator row instead.
    row_chars(s, lp, sep_row).includes?('┼').should be_true
  end
end

# BUGS11 #21 — `Table#draw_borders` iterated by `rows_n`/`@maxes` guarded only by
# the screen-buffer bounds (`lines[...]?`), so a Table clipped by a scrollable /
# `overflow: hidden` ancestor kept stamping gridlines into screen cells below its
# visible rectangle (`coords.yl`). The fix bounds both border passes by the
# rendered coords.
describe "BUGS11 #21 Table#draw_borders is clipped to the rendered coords" do
  it "paints no gridlines below the clipping container's bottom" do
    s = hwindow
    s.alloc
    # A short `overflow: Hidden` container clips the taller table.
    box = Crysterm::Widget::Box.new(parent: s, left: 0, top: 0,
      width: 40, height: 6, overflow: Crysterm::Overflow::Hidden)
    rows = (0...10).map { |i| ["R#{i}a", "R#{i}b"] of String }
    t = Crysterm::Widget::Table.new(parent: box, left: 0, top: 0,
      rows: rows, style: Crysterm::Style.new(border: true))
    s.repaint

    lp = t.lpos.not_nil!
    lp.no_bottom?.should be_true # actually clipped by the ancestor

    natural_bottom = t.height.as(Int32)    # pinned to 2*rows-1 + ivertical (== 21)
    clip_bottom = lp.yl                    # visible bottom (exclusive)
    clip_bottom.should be < natural_bottom # the clip really cut the table

    # No gridline glyph may appear on any row below the clipped bottom — before
    # the fix the junction/`─` passes stamped them all the way down to the
    # table's full pinned height.
    (clip_bottom...natural_bottom).each do |y|
      chars = (0...40).map { |x| s.lines[y][x]?.try(&.char) || ' ' }.join
      leaked = chars.each_char.find { |c| GRID_GLYPHS.includes?(c) }
      leaked.should be_nil
    end
  end
end
