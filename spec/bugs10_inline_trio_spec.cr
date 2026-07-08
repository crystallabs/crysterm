require "./spec_helper"

include Crysterm

# Regression coverage for BUGS10 #1/#2/#3 — physical-vs-surface coordinate
# handling of inline (`alternate: false`) windows:
#   #1 `enter_inline` must emit its scroll newlines from the BOTTOM terminal
#      row (a newline only scrolls from there), not from the anchor row.
#   #2 `Window#draw` must translate the tracked physical cursor row
#      (`tput.cursor.y`) back into surface space before using it as a `@lines`
#      index for the artificial cursor.
#   #3 A dirty (re)alloc resets `@olines` to blanks, so the inline region must
#      be physically erased too — otherwise blank cells diff as unchanged and
#      stale terminal content persists.
private def inline_window(width : Int32? = 40, height : Int32? = 6)
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: width,
    height: height,
    alternate: false,
    default_quit_keys: false,
  )
end

private def alt_window(width = 40, height = 6)
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: width,
    height: height,
    default_quit_keys: false,
  )
end

describe "inline Window physical/surface coordination (BUGS10 #1-#3)" do
  it "scrolls from the bottom row when the region does not fit below the anchor (#1)" do
    win = inline_window(height: 6)
    term_h = win.tput.screen.height
    # Anchor 2 rows above the bottom: 4 of the 6 rows don't fit -> scroll 4.
    win.anchor_row = term_h - 2
    win.output.as(IO::Memory).clear
    win.enter
    out = win.output.as(IO::Memory).to_s

    # The scroll newlines must be emitted right after a cursor move to the
    # LAST row (1-based term_h); from anywhere else they wouldn't scroll.
    out.should match /\e\[#{term_h};1H\n{4}/
    # Anchor moved up by the scrolled amount: region occupies the bottom 6 rows.
    win.render_row_offset.should eq term_h - 6
  end

  it "does not scroll when the region fits below the anchor (#1)" do
    win = inline_window(height: 6)
    win.anchor_row = 2
    win.output.as(IO::Memory).clear
    win.enter
    win.render_row_offset.should eq 2
    win.output.as(IO::Memory).to_s.should_not contain "\n"
  end

  it "paints the artificial cursor at the surface row, not the physical row (#2)" do
    s = inline_window(width: 10, height: 4)
    s.render_row_offset = 10
    s.alloc

    # Stable content; primes @olines to mirror @lines.
    s.lines.size.times { |y| s.lines[y].size.times { |x| s.lines[y][x].char = '.' } }
    s.lines.each &.dirty=(true)
    s.draw

    s.cursor.artificial = true
    s.cursor._hidden = false
    s.cursor._state = 1
    s.cursor.shape = Tput::CursorShape::Block

    # Caret at surface row 2 -> every positioning path tracks the PHYSICAL row
    # (surface + offset = 12) in tput's cursor.
    s.tput.cursor.x = 3
    s.tput.cursor.y = 12
    s.draw

    # The cursor must composite into surface row 2 (REVERSE attr in @olines) —
    # untranslated it would either land on row 12 (out of range here) or not
    # be drawn at all.
    (Attr.flags(s.olines[2][3].attr) & Attr::REVERSE).should_not eq 0
    # No other row got the cursor.
    s.olines.size.times do |y|
      next if y == 2
      (Attr.flags(s.olines[y][3].attr) & Attr::REVERSE).should eq 0
    end
  end

  it "erases exactly the region rows on dirty (re)alloc, with no full-screen clear (#3)" do
    win = inline_window(height: 6)
    win.render_row_offset = 4
    win.output.as(IO::Memory).clear
    win.alloc(dirty: true)
    out = win.output.as(IO::Memory).to_s

    # Region rows 4..9 (1-based 5..10) each erased with EL2.
    (4..9).each do |py|
      out.should contain "\e[#{py + 1};1H\e[2K"
    end
    # Rows just above/below the region untouched; never a full-screen clear.
    out.should_not contain "\e[4;1H\e[2K"
    out.should_not contain "\e[11;1H\e[2K"
    out.should_not contain "\e[2J"
  end

  it "keeps the full-screen clear (no per-row erase) on the alternate path (#3)" do
    alt = alt_window
    alt.output.as(IO::Memory).clear
    alt.alloc(dirty: true)
    alt.output.as(IO::Memory).to_s.should_not contain "\e[2K"
  end
end
