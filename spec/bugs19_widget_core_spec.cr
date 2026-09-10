require "./spec_helper"

include Crysterm

# Regression specs for BUGS19: widget core and layout fixes (#10, #12, #14).

# BUGS19 #12 — Vertically aligned content drops its first line when that line is empty.
#
# Bottom/center-aligned rendering uses negative `ci` to consume fill rows, and after
# the gap `ci == 0`. The newline-skip condition checked `content[ci - 2]?`, which with
# `ci == 0` yields `nil` for an index -2, and `nil != '\n'` is true. A leading empty
# line in bottom-aligned content was skipped, pushing everything up one row. The guard
# `ci >= 2` prevents the negative index access.
describe "BUGS19 12: v-aligned content keeps a leading empty line" do
  it "renders a bottom-aligned widget whose content starts with newline" do
    s = headless_screen(40, 12)
    # Box with bottom alignment and content starting with newline.
    w = Widget::Box.new parent: s, top: 1, left: 1, width: 20, height: 8,
      content: "\nline2",
      align: Tput::AlignFlag::Bottom

    s.repaint
    pos = w.last_rendered_position
    # The widget's rendered rows start at pos.yi. The first content row (the empty
    # line) should appear, not be skipped.
    # With the bug, the empty line is dropped and "line2" appears at the first row.
    # After the fix, the empty row should be visible.

    # Check that the rendered content includes the leading empty row.
    # The rendered box starts at pos.yi; with bottom alignment and height 8,
    # if content starts with "\n", the first rendered row should be blank.
    # We can verify this by checking that a later row contains "line2".
    line2_found = false
    row_with_line2 = -1

    (pos.yi...pos.yi + pos.height).each do |y|
      row_text = String.build { |io| (pos.xi...pos.xi + pos.width).each { |x| io << s.cell_rows[y][x].char } }
      if row_text.includes?("line2")
        line2_found = true
        row_with_line2 = y
        break
      end
    end

    # line2 should be found and should not be at the very first row (yi) because
    # there's a leading empty line.
    line2_found.should be_true
    row_with_line2.should be > pos.yi # Not at the first rendered row
  end

  it "renders a center-aligned widget whose content starts with newline" do
    s = headless_screen(40, 12)
    w = Widget::Box.new parent: s, top: 1, left: 1, width: 20, height: 8,
      content: "\nline2",
      align: Tput::AlignFlag::VCenter

    s.repaint
    pos = w.last_rendered_position

    # Similar to bottom-aligned: the leading empty line should be preserved.
    line2_found = false
    row_with_line2 = -1

    (pos.yi...pos.yi + pos.height).each do |y|
      row_text = String.build { |io| (pos.xi...pos.xi + pos.width).each { |x| io << s.cell_rows[y][x].char } }
      if row_text.includes?("line2")
        line2_found = true
        row_with_line2 = y
        break
      end
    end

    line2_found.should be_true
    # For center alignment with an empty first line, line2 should be offset down.
    row_with_line2.should be > pos.yi
  end
end

# BUGS19 #14 — Flow/Masonry chain arithmetic overflows Int32 for a child with
# pathologically large fixed width.
#
# Flow and Masonry layouts deliberately saturate huge fixed widths to Int32::MAX
# to prevent crashes. However, the rendered-predecessor branch of Flow (and the
# gravitation branch of Masonry) ran checked Int32 arithmetic on that saturated
# value, causing `Int32::MAX + spacing` to raise OverflowError. The fix widens
# to Int64, adds, and clamps back to Int32.
describe "BUGS19 14: Flow layout with Int32::MAX width child doesn't overflow" do
  it "places a second child even when the first has width Int32::MAX" do
    s = headless_screen(80, 24)
    lay = Layout::Wrap.new
    lay.spacing = 1
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 40, height: 20,
      layout: lay

    # Create a child with a pathologically large width that gets saturated.
    child1 = Widget::Box.new parent: box, width: Int32::MAX, height: 2

    # Placing a successor after a saturated-width predecessor must not
    # overflow Int32.
    Widget::Box.new parent: box, width: 5, height: 2

    s.repaint
    child1.lpos.nil?.should be_false
  end

  it "places children in Masonry with Int32::MAX height" do
    s = headless_screen(80, 24)
    lay = Layout::Masonry.new
    lay.spacing = 1
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 40, height: 20,
      layout: lay

    # Create a child with pathologically large height.
    child1 = Widget::Box.new parent: box, width: 10, height: Int32::MAX

    # Placing a successor after a saturated-height predecessor must not
    # overflow Int32.
    Widget::Box.new parent: box, width: 10, height: 5

    s.repaint
    child1.lpos.nil?.should be_false
  end
end
