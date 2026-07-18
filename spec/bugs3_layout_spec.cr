require "./spec_helper"

include Crysterm

# Headless window with grapheme/column-width-aware rendering forced on, so
# `Widget#full_unicode?` reports true (wide CJK/emoji graphemes count as two
# columns). `force_unicode` bypasses the terminal-capability gate that would
# otherwise be false for an `IO::Memory`-backed window.
private def unicode_screen(w = 40, h = 20)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, full_unicode: true, force_unicode: true)
end

private def plain_screen(w = 40, h = 20)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h)
end

# Fix #1: `TableLayout#pad_cell` trims an overflowing cell by DISPLAY WIDTH
# (per-grapheme `Unicode.display_width` under `full_unicode?`), not by character
# count. A cell of wide CJK graphemes whose display width exceeds the column
# width must be trimmed to exactly `width` columns (measured by the same
# `cell_width` the widget uses), never under-trimmed to `width` *characters*.
describe "TableLayout#pad_cell wide-character trim (display-width)" do
  it "reports full_unicode? and counts wide graphemes as two columns" do
    s = unicode_screen
    t = Crysterm::Widget::Table.new parent: s, rows: [["漢字漢字"]]

    s.full_unicode_effective?.should be_true
    # Four CJK graphemes at two columns each.
    t.cell_width("漢字漢字").should eq 8
  end

  it "trims a wide-char cell to the exact display width, not char count" do
    s = unicode_screen
    t = Crysterm::Widget::Table.new parent: s, rows: [["漢字漢字"]]

    cell = "漢字漢字" # display width 8, 4 characters
    # Trim to 4 columns: two wide graphemes fit exactly (2*2 == 4). A
    # char-count trim would have kept 4 characters (display width 8).
    padded = t.pad_cell(cell, 4)
    t.cell_width(padded).should eq 4
    padded.size.should eq 2 # only two graphemes survive the display-width trim
  end

  it "never splits a grapheme, so an odd target width is not overshot" do
    s = unicode_screen
    t = Crysterm::Widget::Table.new parent: s, rows: [["漢字漢字"]]

    # A third wide grapheme would reach display width 6 > 5, so it is dropped:
    # the result is 4 columns wide (<= 5), never 5 (which would require half a
    # grapheme). The invariant checked is cell_width(padded) <= width.
    padded = t.pad_cell("漢字漢字", 5)
    t.cell_width(padded).should be <= 5
    t.cell_width(padded).should eq 4
  end

  it "trims left-aligned wide cells from the end to the exact display width" do
    s = unicode_screen
    t = Crysterm::Widget::Table.new parent: s, rows: [["漢字漢字"]]
    t.cell_align = Tput::AlignFlag::Left

    padded = t.pad_cell("漢字漢字", 4)
    t.cell_width(padded).should eq 4
    padded.should eq "漢字" # kept the leading two graphemes
  end

  it "trims center/right-aligned wide cells from the front" do
    s = unicode_screen
    t = Crysterm::Widget::Table.new parent: s, rows: [["漢字漢字"]]
    t.cell_align = Tput::AlignFlag::Right

    padded = t.pad_cell("漢字漢字", 4)
    t.cell_width(padded).should eq 4
    padded.should eq "漢字" # kept the trailing two graphemes
  end

  it "contrasts with the non-full_unicode path (trim by char count)" do
    s = plain_screen
    t = Crysterm::Widget::Table.new parent: s, rows: [["漢字漢字"]]

    s.full_unicode_effective?.should be_false
    # Without full_unicode each character is measured as one column, so a 4-col
    # trim keeps all four characters unchanged.
    t.pad_cell("漢字漢字", 4).should eq "漢字漢字"
  end
end

# Fix #2: in the stretched (auto width/height) branch of `awidth`/`aheight`, the
# margin is subtracted BEFORE clamping to `[min, max]`, so the constraint applies
# to the post-margin (used) size, per CSS min/max semantics. With a 10-column
# slot, 4 columns of horizontal margin and `min_width: 10`, the post-margin size
# is 6, which `min_width` must lift back to 10.
describe "Widget size auto-branch clamps the post-margin size" do
  it "applies min_width to the margin-reduced auto width" do
    s = plain_screen
    parent = Widget::Box.new parent: s, left: 0, top: 0, width: 10, height: 10
    child = Widget::Box.new parent: parent, left: 0, top: 0,
      style: Style.new(margin: Margin.new(2, 0, 2, 0))

    parent.awidth.should eq 10

    # Baseline: auto width fills the 10-col slot then folds in the 4 cols of
    # horizontal margin -> 6.
    child.awidth.should eq 6

    # With min_width: the clamp is applied to the post-margin size (6), lifting
    # it to 10. Pre-fix, the clamp ran before the margin subtraction and this
    # would not hold.
    child.min_width = 10
    child.awidth.should eq 10
  end

  it "applies min_height to the margin-reduced auto height" do
    s = plain_screen
    parent = Widget::Box.new parent: s, left: 0, top: 0, width: 10, height: 10
    child = Widget::Box.new parent: parent, left: 0, top: 0,
      style: Style.new(margin: Margin.new(0, 2, 0, 2))

    parent.aheight.should eq 10

    child.aheight.should eq 6

    child.min_height = 10
    child.aheight.should eq 10
  end

  it "still clamps the auto width down with max_width on the post-margin size" do
    s = plain_screen
    parent = Widget::Box.new parent: s, left: 0, top: 0, width: 10, height: 10
    child = Widget::Box.new parent: parent, left: 0, top: 0,
      style: Style.new(margin: Margin.new(1, 0, 1, 0))

    # Post-margin auto width: 10 - 2 = 8.
    child.awidth.should eq 8

    # max_width caps the post-margin size.
    child.max_width = 5
    child.awidth.should eq 5
  end
end
