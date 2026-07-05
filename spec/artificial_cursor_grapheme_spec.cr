require "./spec_helper"

include Crysterm

# Regression: in `full_unicode` mode the `#draw` emit path re-reads a cell's
# grapheme-cluster overlay straight from the row (`line.grapheme_at?(x)`) and
# printed it. A glyph-replacing artificial cursor (the `line` shape's bar, or a
# custom `none` shape's `fill_char`) sets a per-cell `desired_char` override,
# but the overlay re-read ignored it — so over a multi-codepoint cluster cell
# (e.g. `e` + combining acute) the cursor glyph was never shown and `@olines`
# recorded the cluster, not the cursor. Block/underline cursors change only the
# attribute and must still keep the cell's own cluster.
#
# After `#draw`, `@olines` mirrors exactly what was emitted, so it is the
# observable here.
private def fu_screen(width = 8, height = 2)
  s = Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height)
  s.full_unicode = true
  s
end

private def place_cursor(s, y, x, shape)
  s.tput.cursor.x = x
  s.tput.cursor.y = y
  c = s.cursor
  c.artificial = true
  c.shape = shape
  c._hidden = false
  c._state = 1
end

describe "Window#draw artificial cursor over a grapheme cluster (full_unicode)" do
  it "renders a line cursor's bar over a cluster cell, not the cluster" do
    s = fu_screen
    pending! "full_unicode unavailable in this environment" unless s.full_unicode?
    s.alloc
    y, x = 0, 3
    s.lines[y][x].grapheme = "e\u{0301}"
    s.lines[y].dirty = true
    place_cursor s, y, x, Tput::CursorShape::Line
    s.draw

    # The cursor glyph replaced the cluster: single '│', no overlay left behind.
    s.olines[y][x].char.should eq '│'
    s.olines[y][x].grapheme_overlay.should be_nil
  end

  it "renders a custom (none-shape) cursor's fill_char over a cluster cell" do
    s = fu_screen
    pending! "full_unicode unavailable in this environment" unless s.full_unicode?
    s.alloc
    y, x = 1, 2
    s.lines[y][x].grapheme = "e\u{0301}"
    s.lines[y].dirty = true
    place_cursor s, y, x, Tput::CursorShape::None
    s.cursor.style.fill_char = '#'
    s.draw

    s.olines[y][x].char.should eq '#'
    s.olines[y][x].grapheme_overlay.should be_nil
  end

  it "keeps the cell's own cluster for a block cursor (attribute-only)" do
    s = fu_screen
    pending! "full_unicode unavailable in this environment" unless s.full_unicode?
    s.alloc
    y, x = 0, 2
    s.lines[y][x].grapheme = "e\u{0301}"
    s.lines[y].dirty = true
    place_cursor s, y, x, Tput::CursorShape::Block
    s.draw

    # A block cursor only reverses the cell; the cluster stays intact, and the
    # REVERSE attribute confirms the cursor actually engaged.
    s.olines[y][x].grapheme_overlay.should eq "e\u{0301}"
    (Attr.flags(s.olines[y][x].attr) & Attr::REVERSE).should_not eq 0
  end
end
