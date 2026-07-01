require "./spec_helper"

include Crysterm

# Regression specs for the three headless-testable fixes in BUGS3.
#
# Two fixes live in `TerminalEmulator` (RIS state clearing, OSC embedded-ESC
# preservation) and are driven by constructing the emulator directly and calling
# `#feed` — the same headless-parse pattern the widget's reader fiber uses, minus
# the PTY.
#
# The third fix lives in `Widget::Terminal#draw` (wide-glyph continuation kept
# even when the cursor sits on the lead half), so it is driven through a real
# render of the widget onto a headless `Window`, then inspecting `window.lines`.
#
# NOT covered here: the PTY `resize`/`ioctl` fix, which needs a real pseudo-
# terminal (`TIOCSWINSZ` on a live master fd) and cannot be exercised from a
# headless unit test.

private def default_attr : Int64
  # A plain packed attribute (default fg/bg, no flags) is all the emulator needs
  # for these grid-shape assertions.
  Attr.pack(0_i64, -1, -1)
end

private def emulator(cols = 20, rows = 5) : TerminalEmulator
  TerminalEmulator.new cols, rows, default_attr
end

# The character in the emulator grid at (x, y) of the live viewport.
private def cell_char(em : TerminalEmulator, x : Int32, y : Int32) : Char
  em.lines[em.ybase + y][x].char
end

# Reads back the current row (live viewport row 0) as a String, stripping the
# trailing blanks, so grid content can be asserted without caring about padding.
private def row_text(em : TerminalEmulator, y = 0) : String
  em.lines[em.ybase + y].map(&.char).join.rstrip(' ')
end

describe "TerminalEmulator RIS reset (fix #3)" do
  it "clears a partial CSI so post-reset input is not spliced onto it" do
    em = emulator
    # Feed an incomplete CSI (ESC [ with a partial parameter, no final byte),
    # then RIS, then a normal glyph. Without the fix the stale `@csi_buf` (`12`)
    # would still be in the parser and the following 'A' would be interpreted as
    # part of / after a CSI rather than printed as text at (0,0).
    em.feed "\e[12"
    em.feed "\ec" # RIS
    em.feed "A"

    # 'A' must land as plain text at home, cursor advanced by exactly one.
    cell_char(em, 0, 0).should eq 'A'
    em.cursor_x.should eq 1
    em.cursor_y.should eq 0
    row_text(em).should eq "A"
  end

  it "clears a private/prefixed partial CSI across a reset" do
    em = emulator
    # Partial DEC-private CSI (`ESC [ ? 2` — could have become `?2004h`, etc.).
    em.feed "\e[?2"
    em.feed "\ec" # RIS clears @csi_prefix / @csi_private too
    em.feed "Z"

    cell_char(em, 0, 0).should eq 'Z'
    em.cursor_x.should eq 1
    row_text(em).should eq "Z"
  end

  it "drops a partial UTF-8 lead byte held over from before the reset" do
    em = emulator
    # A lone UTF-8 lead byte (0xE4 begins a 3-byte sequence, e.g. '中') is held
    # back in `@leftover` awaiting its continuation bytes. RIS must drop it so it
    # is not prepended to — and thus corrupt — the next feed.
    em.feed Bytes[0xE4]
    em.feed "\ec".to_slice # RIS clears @leftover
    em.feed "X".to_slice

    cell_char(em, 0, 0).should eq 'X'
    em.cursor_x.should eq 1
    row_text(em).should eq "X"
  end

  it "resets cursor and grid content on RIS" do
    em = emulator
    em.feed "hello\r\nworld"
    em.feed "\ec"
    # Whole grid blanked, cursor home.
    em.cursor_x.should eq 0
    em.cursor_y.should eq 0
    row_text(em, 0).should eq ""
    row_text(em, 1).should eq ""
  end
end

describe "TerminalEmulator OSC embedded ESC (fix #2)" do
  it "preserves a literal ESC (not forming ST) inside an OSC string" do
    captured = nil.as(String?)
    em = emulator
    em.on_title = ->(t : String) { captured = t; nil }

    # OSC 0 (set title) whose payload contains an ESC that is NOT followed by
    # '\' (so it is not an ST terminator). The ESC belongs to the payload and
    # must be preserved; the whole sequence is terminated by BEL.
    # Payload: "a" ESC "b"  → title should be "a\eb".
    em.feed "\e]0;a\eb\a"

    captured.should eq "a\eb"
  end

  it "does not corrupt following grid text after an OSC with embedded ESC" do
    em = emulator
    em.feed "\e]0;x\ey\a" # OSC with embedded ESC, BEL-terminated
    em.feed "OK"

    # Parser returned cleanly to ground; the following text is intact at home.
    cell_char(em, 0, 0).should eq 'O'
    cell_char(em, 1, 0).should eq 'K'
    row_text(em).should eq "OK"
  end

  it "still treats a real ST (ESC \\) as the OSC terminator" do
    captured = nil.as(String?)
    em = emulator
    em.on_title = ->(t : String) { captured = t; nil }

    em.feed "\e]0;title\e\\" # proper ST terminator
    em.feed "Z"

    captured.should eq "title"
    cell_char(em, 0, 0).should eq 'Z'
  end
end

# ── Fix #1: wide-glyph continuation kept even under the cursor. ──
#
# This is the widget draw path, so it needs a rendered widget over a headless
# window with full_unicode in effect (force_unicode makes the terminal report
# the unicode capability the full_unicode? gate requires).
private def unicode_screen
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: 24,
    force_unicode: true, full_unicode: true)
end

describe "Widget::Terminal wide glyph under cursor (fix #1)" do
  it "keeps the continuation cell and advances 2 columns when the cursor sits on the lead half" do
    s = unicode_screen
    s.full_unicode?.should be_true # precondition: the gate the draw path checks

    term = Crysterm::Widget::Terminal.new(
      parent: s, top: 0, left: 0, width: 10, height: 4,
      handler: ->(_data : String) { nil })

    s._render
    term.focus # cursor must be shown for the lead-under-cursor branch to matter

    em = term.emulator
    em.should_not be_nil
    em = em.not_nil!

    # Feed a single wide (2-column) CJK glyph: print_char places it at (0,0),
    # marks (1,0) as continuation, and advances @x by 2 → cursor on column 2.
    # Move the cursor back two columns so it sits squarely on the glyph's LEAD
    # half (column 0) — the case fix #1 addresses.
    em.feed "中"
    em.feed "\e[D\e[D" # CUB x2 → onto the lead cell
    em.cursor_x.should eq 0

    s._render

    line = s.lines[0]
    # Lead cell holds the wide glyph.
    ::Crysterm::Unicode.width(line[0].char).should eq 2
    # The following window cell is a continuation (1 window cell == 1 terminal
    # column preserved), even though the cursor sits on the lead half.
    line[1].continuation?.should be_true
    # The cell after the wide pair is a normal (non-continuation) blank.
    line[2].continuation?.should be_false
  ensure
    term.try &.kill
    s.try &.destroy
  end

  it "renders a wide glyph as lead + continuation even without the cursor on it" do
    s = unicode_screen
    term = Crysterm::Widget::Terminal.new(
      parent: s, top: 0, left: 0, width: 10, height: 4,
      handler: ->(_data : String) { nil })
    s._render

    em = term.emulator.not_nil!
    # Print the glyph then move the cursor well away so it is not over the pair.
    em.feed "中"
    em.feed "\e[5G" # cursor to column 5 (1-based) → away from the glyph
    s._render

    line = s.lines[0]
    ::Crysterm::Unicode.width(line[0].char).should eq 2
    line[1].continuation?.should be_true
  ensure
    term.try &.kill
    s.try &.destroy
  end
end
