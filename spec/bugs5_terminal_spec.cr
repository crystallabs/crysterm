require "./spec_helper"

include Crysterm

# Regression specs for BUGS5.
#
#   BUG 1  Widget::Terminal#draw — cursor on the TRAILING (continuation) half of
#          a wide glyph must stay visible (widget render path).
#   BUG 2  TerminalEmulator#full_reset — RIS must reset the DECSC/DECRC save slot
#          so a later DECRC (`ESC 8`) doesn't restore pre-reset state.
#   BUG 3  Widget::Terminal#apply_cursor — a `:line` (bar) cursor must not hide
#          the cell's glyph/attribute.
#   BUG 4  Widget::TerminalPTY#initialize — a failed spawn must not leak the
#          freshly-opened PTY fds (see the note near the end for why this is
#          not exercised at runtime here).

private def default_attr : Int64
  Attr.pack(0_i64, -1, -1)
end

private def emulator(cols = 20, rows = 5) : TerminalEmulator
  TerminalEmulator.new cols, rows, default_attr
end

private def cell_char(em : TerminalEmulator, x : Int32, y : Int32) : Char
  em.lines[em.ybase + y][x].char
end

private def row_text(em : TerminalEmulator, y = 0) : String
  em.lines[em.ybase + y].map(&.char).join.rstrip(' ')
end

private def unicode_screen
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: 24,
    force_unicode: true, full_unicode: true)
end

# ── BUG 1: cursor on the trailing half of a wide glyph stays visible. ──
describe "Widget::Terminal cursor on wide-glyph continuation half (BUG 1)" do
  it "applies cursor styling to the continuation cell instead of swallowing the cursor column" do
    s = unicode_screen
    s.full_unicode?.should be_true

    term = Crysterm::Widget::Terminal.new(
      parent: s, top: 0, left: 0, width: 10, height: 4,
      cursor_shape: :block, # inverts the cursor cell — easy to detect
      handler: ->(_data : String) { nil }    )

    s._render
    term.focus # cursor must be shown for the branch to matter

    em = term.emulator.not_nil!

    # Wide (2-column) glyph at cols 0-1, then CHA to 1-based col 2 → 0-based
    # col 1, the glyph's CONTINUATION (trailing) half.
    em.feed "世\e[2G"
    em.cursor_x.should eq 1

    s._render

    line = s.lines[0]
    # Grid invariant preserved: lead holds the wide glyph, next cell is its
    # continuation.
    ::Crysterm::Unicode.width(line[0].char).should eq 2
    line[1].continuation?.should be_true
    # BUG 1: the cursor column (the continuation cell) carries the block-cursor
    # styling (REVERSE) rather than a plain continuation — so the cursor shows.
    (Attr.flags(line[1].attr) & Attr::REVERSE).should_not eq 0
  ensure
    term.try &.kill
    s.try &.destroy
  end

  it "leaves the continuation cell unstyled when the cursor is elsewhere (no false positive)" do
    s = unicode_screen
    term = Crysterm::Widget::Terminal.new(
      parent: s, top: 0, left: 0, width: 10, height: 4,
      cursor_shape: :block,
      handler: ->(_data : String) { nil })
    s._render
    term.focus

    em = term.emulator.not_nil!
    em.feed "世\e[5G" # cursor to col 5, away from the glyph pair
    s._render

    line = s.lines[0]
    line[1].continuation?.should be_true
    (Attr.flags(line[1].attr) & Attr::REVERSE).should eq 0
  ensure
    term.try &.kill
    s.try &.destroy
  end
end

# ── BUG 2: RIS resets the DECSC/DECRC save slot. ──
describe "TerminalEmulator RIS clears the DECSC save slot (BUG 2)" do
  it "does not restore the pre-reset cursor position after ESC 8" do
    em = emulator
    em.feed "\e[3;5H" # move cursor to row 3, col 5 (1-based)
    em.feed "\e7"     # DECSC: save cursor
    em.feed "\ec"     # RIS: must also reset the save slot to home
    em.feed "\e8"     # DECRC: restore — should land at home, not (4,2)

    em.cursor_x.should eq 0
    em.cursor_y.should eq 0
  end

  it "does not re-enable a saved line-drawing charset after ESC 8" do
    em = emulator
    em.feed "\e(0" # designate G0 as DEC line-drawing (special)
    em.feed "\e7"  # DECSC snapshots g0_special = true
    em.feed "\ec"  # RIS resets both active and saved charset state
    em.feed "\e8"  # DECRC restores — g0_special must remain false
    em.feed "q"    # in line-drawing 'q' maps to '─'; as ASCII it stays 'q'

    cell_char(em, 0, 0).should eq 'q'
    row_text(em).should eq "q"
  end
end

# ── BUG 3: a :line (bar) cursor overlays, it does not hide the glyph. ──
describe "Widget::Terminal :line cursor preserves the underlying glyph (BUG 3)" do
  it "keeps the cell's character (and attribute) under a :line cursor" do
    s = Crysterm::Window.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 80, height: 24)

    term = Crysterm::Widget::Terminal.new(
      parent: s, top: 0, left: 0, width: 10, height: 4,
      cursor_shape: :line,
      handler: ->(_data : String) { nil })
    s._render
    term.focus

    em = term.emulator.not_nil!
    em.feed "X\e[G" # print 'X' at (0,0), then CHA back onto it
    em.cursor_x.should eq 0
    s._render

    line = s.lines[0]
    # The glyph under the bar cursor is preserved (not replaced by '│').
    line[0].char.should eq 'X'
  ensure
    term.try &.kill
    s.try &.destroy
  end
end

# ── BUG 4: PTY fd leak on spawn failure. ──
#
# The fix wraps `spawn_child` in a begin/rescue that closes both `@master` and
# the slave fd before re-raising, so a `File::NotFoundError` from a bad command
# on the no-setsid fallback path no longer leaks the freshly-opened descriptors.
#
# This is not asserted at runtime here, and deliberately so:
#   * Proving the fds are actually closed would need to inspect the process fd
#     table.
#   * The rescue branch that closes them is only reached on the *no-setsid*
#     fallback path. On a host where `setsid` exists (typical Linux),
#     `Process.new("setsid", ...)` succeeds and the child fails to exec the bad
#     command asynchronously — so `initialize` does NOT raise, and whether it
#     raises is environment-dependent. An `expect_raises` here would pass on
#     macOS and fail on Linux.
# So the fix is guarded by compilation only: the `pending` block below is
# type-checked (never executed), pinning the constructor signature the fix
# lives in. FLAG: no dedicated runtime assertion is feasible in a headless unit
# test.
describe "Widget::TerminalPTY spawn failure (BUG 4)" do
  pending "closes both PTY fds before re-raising a failed spawn (compile-checked only)" do
    pty = Crysterm::Widget::TerminalPTY.new(
      "/nonexistent/definitely-not-a-real-binary",
      [] of String, 80, 24)
    pty.process
  end
end
