require "./spec_helper"

include Crysterm

# Regression coverage for the interaction of the artificial cursor with the BCE
# (back-color-erase) clear-to-EOL optimization in `Screen#draw`
# (`screen_drawing.cr`).
#
# With BCE enabled, a run of clearable blank cells reaching the end of the line
# is collapsed into a single `el` (erase-to-EOL) instead of emitting each space.
# The look-ahead that finds that run reads the cell buffer directly — but the
# artificial cursor's reverse/glyph attribute is composited only into the
# per-cell loop's local `desired_attr`, never into the buffer. So a blank run
# that happened to cover the cursor's column would be erased and the row scan
# broken out of BEFORE the cursor cell was emitted, leaving the cursor undrawn
# for that frame. The cursor cell must be excluded from the clearable run.
private def bce_cursor_screen(width = 10, height = 4)
  s = Crysterm::Screen.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height)
  s.optimization = Crysterm::OptimizationFlag::BCE
  s
end

describe "Screen#draw artificial cursor + BCE" do
  it "draws the artificial cursor even inside a clearable blank run" do
    s = bce_cursor_screen
    s.alloc

    # Sync @olines to @lines (an all-blank buffer).
    s.lines.each &.dirty=(true)
    s.draw

    y = 1
    cx = 5

    # Force a difference somewhere in the (otherwise all-blank) row so the BCE
    # look-ahead's "this run differs from screen" test (`neq`) is satisfied and
    # the clear-to-EOL path actually fires. The buffer cell stays a blank, so
    # the whole row from column 0 is a clearable run that spans the cursor.
    s.olines[y][8].char = '.'

    # Paint a visible artificial block cursor at (cx, y).
    s.cursor.artificial = true
    s.cursor._hidden = false
    s.cursor._state = 1
    s.cursor.shape = Tput::CursorShape::Block
    s.tput.cursor.x = cx
    s.tput.cursor.y = y

    s.draw

    # The cursor must have been painted: its cell carries REVERSE in @olines.
    # Before the fix, the BCE clear-to-EOL erased over column `cx` and broke out
    # of the row scan, so the cursor was never emitted and this flag was 0.
    (Attr.flags(s.olines[y][cx].attr) & Attr::REVERSE).should_not eq 0
  end
end
