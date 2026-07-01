require "./spec_helper"

include Crysterm

# Regression: artificial cursor vs. the BCE (back-color-erase) clear-to-EOL
# optimization in `Window#draw` (`window_drawing.cr`).
#
# With BCE enabled, a run of clearable blank cells reaching EOL collapses into
# a single `el` instead of emitting each space. The look-ahead for that run
# reads the cell buffer directly, but the artificial cursor's reverse/glyph
# attribute is composited only into the per-cell loop's local `desired_attr`,
# never into the buffer — so a blank run covering the cursor's column got
# erased and broke out of the row scan before the cursor cell was emitted,
# leaving the cursor undrawn. The cursor cell must be excluded from the
# clearable run.
private def bce_cursor_screen(width = 10, height = 4)
  s = Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height)
  s.optimization = Crysterm::OptimizationFlag::BCE
  s
end

describe "Window#draw artificial cursor + BCE" do
  it "draws the artificial cursor even inside a clearable blank run" do
    s = bce_cursor_screen
    s.alloc

    # Sync @olines to @lines (an all-blank buffer).
    s.lines.each &.dirty=(true)
    s.draw

    y = 1
    cx = 5

    # Force a difference in the (otherwise all-blank) row so the BCE look-ahead's
    # `neq` test fires the clear-to-EOL path. The buffer cell stays blank, so the
    # whole row from column 0 is a clearable run that spans the cursor.
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
    # Before the fix, BCE clear-to-EOL erased over column `cx` and broke out of
    # the row scan, so this flag was 0.
    (Attr.flags(s.olines[y][cx].attr) & Attr::REVERSE).should_not eq 0
  end
end
