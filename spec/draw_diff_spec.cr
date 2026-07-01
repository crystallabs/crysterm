require "./spec_helper"

include Crysterm

# Regression coverage for the per-cell diff in `Window#draw` (`window_drawing.cr`).
#
# `draw` compares `@lines` (this frame) against `@olines` (what is on the
# terminal), skips unchanged cells, and writes every emitted cell back into
# `@olines`. After a `draw`, `@olines` mirrors exactly what the diff emitted —
# used as the observable below.
#
# Bug guarded against (full_unicode): `desired_char` is only the BASE codepoint
# of a cell, so a compare ignoring the grapheme overlay treated 'e' and
# 'e'+combining-mark as equal and never emitted the mark.

private def fu_screen(output = IO::Memory.new, width = 10, height = 3)
  s = Crysterm::Window.new(
    input: IO::Memory.new, output: output, error: IO::Memory.new,
    width: width, height: height)
  s.full_unicode = true
  s
end

describe "Window#draw cell diff (full_unicode)" do
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

    # Frame 2: same base 'e' and attr, now a 2-codepoint cluster (e + combining
    # acute). Ignoring the overlay would skip this cell and lose the mark.
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

    # Redraw identical content: unchanged, so the diff must skip it and write
    # nothing. (Keying the skip on the OLD cell's overlay would re-emit every frame.)
    before = output.size
    s.lines[y].dirty = true
    s.draw
    (output.size - before).should eq 0
  end
end

# The per-row dirty-column range (`Row#mark_dirty(x)` + the bounded scan in
# `draw`) must be byte-for-byte identical to a full-width scan: it only skips
# unchanged leading/trailing columns, never changes what is emitted. Asserted
# by applying the same edits two ways — narrowed and full — and comparing bytes.
private def plain_screen(output, width = 40, height = 6)
  s = Crysterm::Window.new(
    input: IO::Memory.new, output: output, error: IO::Memory.new,
    width: width, height: height)
  s.alloc
  s
end

# Applies *edits* (`{y, x, char, attr}`) to a freshly-primed screen, marking
# rows dirty via `mark_dirty(x)` when *narrowed* else `dirty = true`, and
# returns the exact bytes the resulting `draw` emits.
private def drawn_bytes(edits, narrowed : Bool, width = 40, height = 6) : Bytes
  buf = IO::Memory.new
  s = plain_screen buf, width, height
  s.draw # prime: @olines mirrors @lines
  buf.clear
  edits.each do |(y, x, ch, at)|
    cell = s.lines[y][x]
    cell.attr = at
    cell.char = ch
    if narrowed
      s.lines[y].mark_dirty x
    else
      s.lines[y].dirty = true
    end
  end
  s.draw
  buf.to_slice.dup
end

describe "Window#draw dirty-column range" do
  red = Attr.pack(0_i64, Attr.pack_color(0xFF0000), Attr.pack_color(0x000000))
  blue = Attr.pack(0_i64, Attr.pack_color(0x0000FF), Attr.pack_color(0x000000))

  {
    "single mid-row cell"        => [{2, 20, 'X', red}],
    "cell at column 0"           => [{1, 0, 'A', red}],
    "cell at last column"        => [{1, 39, 'Z', red}],
    "two cells with a gap"       => [{3, 5, 'a', red}, {3, 30, 'b', blue}],
    "contiguous run"             => [{0, 10, '1', red}, {0, 11, '2', red}, {0, 12, '3', red}],
    "multiple rows, sparse"      => [{0, 5, 'p', red}, {2, 5, 'q', red}, {5, 5, 'r', blue}],
    "differing attrs in one row" => [{4, 2, 'm', red}, {4, 8, 'n', blue}, {4, 14, 'o', red}],
    "full first + last columns"  => [{2, 0, 'L', blue}, {2, 39, 'R', red}],
  }.each do |name, edits|
    it "emits identical bytes to a full scan: #{name}" do
      String.new(drawn_bytes(edits, narrowed: true))
        .should eq String.new(drawn_bytes(edits, narrowed: false))
    end
  end

  it "produces actual output (guards against the no-op trap)" do
    drawn_bytes([{2, 20, 'X', red}], narrowed: true).size.should be > 0
  end
end

# End-to-end guard for the render path driving the dirty-column range (the
# `mark_dirty(x)` calls in `widget_rendering`/`fill_region`/`docking`).
# Invariant: after `draw`, `@olines` mirrors `@lines` exactly. A cell that
# changed but fell outside a too-narrow dirty range would be skipped, leaving
# `@olines` stale — asserted here can't happen as widgets move and change.
private def fully_synced(s) : {Int32, Int32}?
  s.lines.size.times do |y|
    line = s.lines[y]
    o = s.olines[y]?
    next unless o
    Math.min(line.size, o.size).times do |x|
      lc = line[x]
      oc = o[x]
      return {x, y} if lc.attr != oc.attr || lc.char != oc.char || lc.grapheme_overlay != oc.grapheme_overlay
    end
  end
  nil
end

describe "Window#draw end-to-end dirty-range sync" do
  it "leaves @olines mirroring @lines as widgets change content and move" do
    s = Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
    outer = Widget::Box.new parent: s, left: 0, top: 0, width: 40, height: 12
    label = Widget::Box.new parent: outer, left: 2, top: 1, width: 20, height: 1, content: "frame 0"
    side = Widget::Box.new parent: outer, left: 2, top: 3, width: 1, height: 6, content: "|"

    s._render; s.draw
    fully_synced(s).should be_nil

    # Change content in place (a few cells in one row).
    label.set_content "updated text here"
    s._render; s.draw
    fully_synced(s).should be_nil

    # Move a widget (clears old cells, paints new ones at different columns).
    label.left = 10
    s._render; s.draw
    fully_synced(s).should be_nil

    # Shorten content (trailing cells must be cleared back).
    label.set_content "x"
    s._render; s.draw
    fully_synced(s).should be_nil

    # Move the vertical bar across columns (sparse change across many rows).
    side.left = 30
    s._render; s.draw
    fully_synced(s).should be_nil
  end
end
