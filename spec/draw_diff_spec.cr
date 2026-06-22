require "./spec_helper"

include Crysterm

# Regression coverage for the per-cell diff in `Screen#draw` (`screen_drawing.cr`).
#
# `draw` compares `@lines` (this frame) against `@olines` (what is on the
# terminal), skips cells that did not change, and writes every emitted cell back
# into `@olines`. So after a `draw`, `@olines` mirrors exactly the cells the diff
# chose to emit: a changed cell that is wrongly skipped leaves its `@olines`
# entry stale, and a cell that is emitted leaves bytes in the output IO. Both are
# used as observables below.
#
# The bug these guard against (full_unicode): the diff's `desired_char` is only
# the BASE codepoint of a cell, so a compare that ignores the new cell's grapheme
# overlay treated 'e' and 'e'+combining-mark as equal and never emitted the mark.

private def fu_screen(output = IO::Memory.new, width = 10, height = 3)
  s = Crysterm::Screen.new(
    input: IO::Memory.new, output: output, error: IO::Memory.new,
    width: width, height: height)
  s.full_unicode = true
  s
end

describe "Screen#draw cell diff (full_unicode)" do
  it "re-emits a cell when its grapheme cluster changes but base char + attr do not" do
    s = fu_screen
    pending! "full_unicode unavailable in this environment" unless s.full_unicode?
    s.alloc
    y, x = 1, 2

    # Frame 1: a plain 'e' -> @olines mirrors it.
    s.lines[y][x].char = 'e'
    s.lines[y].dirty = true
    s.draw
    s.olines[y][x].char.should eq 'e'
    s.olines[y][x].grapheme_overlay.should be_nil

    # Frame 2: same base 'e' and same attr, now a 2-codepoint cluster
    # (e + combining acute). A diff that ignored the new overlay would skip this
    # cell, leaving @olines stale at a bare 'e' (the combining mark lost).
    s.lines[y][x].grapheme = "e\u{0301}"
    s.lines[y].dirty = true
    s.draw

    s.olines[y][x].grapheme.should eq "e\u{0301}"
    s.olines[y][x].grapheme_overlay.should eq "e\u{0301}"
  end

  it "re-emits a cell when its cluster collapses back to a single codepoint" do
    s = fu_screen
    pending! "full_unicode unavailable in this environment" unless s.full_unicode?
    s.alloc
    y, x = 0, 1

    s.lines[y][x].grapheme = "e\u{0301}"
    s.lines[y].dirty = true
    s.draw
    s.olines[y][x].grapheme_overlay.should eq "e\u{0301}"

    # Back to a plain 'e' (overlay dropped) — the cell changed, so it must emit.
    s.lines[y][x].char = 'e'
    s.lines[y].dirty = true
    s.draw
    s.olines[y][x].char.should eq 'e'
    s.olines[y][x].grapheme_overlay.should be_nil
  end

  it "does not re-emit a genuinely unchanged cluster cell on the next frame" do
    output = IO::Memory.new
    s = fu_screen output
    pending! "full_unicode unavailable in this environment" unless s.full_unicode?
    s.alloc
    y, x = 2, 3

    s.lines[y][x].grapheme = "e\u{0301}"
    s.lines[y].dirty = true
    s.draw
    s.olines[y][x].grapheme.should eq "e\u{0301}"

    # Redraw identical content: the cell is unchanged, so the diff must skip it
    # and write nothing. (A compare that keyed the skip on the OLD cell's overlay
    # would needlessly re-emit this cluster cell every frame.)
    before = output.size
    s.lines[y].dirty = true
    s.draw
    (output.size - before).should eq 0
  end
end
