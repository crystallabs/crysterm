require "./spec_helper"

include Crysterm

private def headless_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

# Behavior lock for `TableLayout#pad_cell` and the `@maxes` column-width cache.
#
# `pad_cell` was rewritten from two allocate-per-iteration loops (pad then trim)
# into a single computed pad/trim. The oracle below reproduces the original loop
# semantics exactly (including centred-odd-remainder overshoot-then-trim), so
# the rewrite is pinned across alignments, cell contents and widths.
describe "TableLayout#pad_cell" do
  # Exact pre-rewrite logic. For tag-free ASCII, display width == char count,
  # so `cell.size` stands in for `cell_width`.
  old = ->(cell : String, width : Int32, align : Tput::AlignFlag) do
    clen = cell.size
    while clen < width
      if align.h_center?
        cell = " #{cell} "; clen += 2
      elsif align.right?
        cell = " #{cell}"; clen += 1
      else
        cell = "#{cell} "; clen += 1
      end
    end
    while clen > width && !cell.empty?
      cell = (align.h_center? || align.right?) ? cell[1..] : cell[0...-1]
      clen -= 1
    end
    cell
  end

  it "matches the old pad/trim loops across alignments, cells and widths" do
    s = headless_screen
    t = Crysterm::Widget::Table.new parent: s, rows: [["x"]]

    aligns = [Tput::AlignFlag::Left, Tput::AlignFlag::Right, Tput::AlignFlag::Center]
    cells = ["", "a", "ab", "abc", "abcd", "abcde", "hello world"]

    aligns.each do |a|
      t.cell_align = a
      cells.each do |c|
        (0..14).each do |w|
          t.pad_cell(c, w).should eq old.call(c, w, a)
        end
      end
    end
  end
end

describe "TableLayout @maxes cache" do
  it "recomputes column widths when the data changes (cache is not stale)" do
    s = headless_screen
    t = Crysterm::Widget::Table.new parent: s, rows: [["a", "b"]]
    narrow = t.row_width

    t.rows = [["aaaaaaaa", "bbbbbbbb"]]
    wide = t.row_width

    wide.should be > narrow
  end

  it "returns a stable result when recomputed without changes" do
    s = headless_screen
    t = Crysterm::Widget::Table.new parent: s, rows: [["a", "bb"], ["ccc", "d"]]

    t.calculate_maxes
    first = t.row_width
    t.calculate_maxes # cache hit: must not change widths
    t.row_width.should eq first
  end
end

describe "TableLayout#col_for_x" do
  # `col_for_x` resolves an interior x to its table column for per-cell CSS
  # styling. Must agree with the rendered layout, which inserts one separator
  # cell between columns (`render_row`, `column_start_offsets`); previously the
  # mapping drifted left by one cell per preceding column.
  it "maps each column to its rendered start position" do
    s = headless_screen
    t = Crysterm::Widget::Table.new parent: s, rows: [["aa", "bbbb", "cc"], ["dd", "ee", "ff"]]
    t.calculate_maxes

    starts = t.column_start_offsets
    map = t.col_for_x(0, 0)

    # Each column's start offset must map to that column; the separator cell
    # just before it must not.
    starts.each_with_index do |start, col|
      map[start]?.should eq col
      map[start - 1]?.should_not eq col if start > 0
    end
  end
end
