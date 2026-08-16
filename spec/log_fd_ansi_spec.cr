require "./spec_helper"

include Crysterm

# Specs for `Widget::LogFd`'s `:ansi` mode (the `ncsubproc`-with-colour case):
# bytes go to an embedded `TerminalEmulator` sized to the widget's content area
# and its grid is painted over the widget, instead of being appended as literal
# text.
#
# Colours are asserted straight off the window cells (`cell_fg`/`cell_bg` unpack
# to `0xRRGGBB`, or -1 for "screen default"), which is what
# `widget_terminal_colors_spec.cr` checks through `Window#dump` for the Terminal
# widget: SGR 31/44 are xterm's #cd0000/#0000ee.

private def ansi_plane(win, width = 20, height = 4)
  Crysterm::Widget::LogFd.new(io: IO::Memory.new(""), mode: :ansi, parent: win,
    top: 1, left: 2, width: width, height: height)
end

# Top-left cell of the widget's *content* area (border/padding excluded), i.e.
# where emulator cell (0, 0) lands. Only valid after a render.
private def content_origin(fd)
  r = fd.contents_rect.not_nil!
  {r.left, r.top}
end

describe "Widget::LogFd :ansi mode" do
  it "paints SGR-coloured cells into the widget's content area" do
    win = headless_screen 40, 10
    fd = ansi_plane win
    win.repaint # bootstrap: sizes and attaches the emulator
    fd.feed "\e[31;44mHi"
    win.repaint

    x, y = content_origin fd
    cell_char(win, x, y).should eq 'H'
    cell_char(win, x + 1, y).should eq 'i'
    cell_fg(win, x, y).should eq 0xcd0000
    cell_bg(win, x, y).should eq 0x0000ee
    # SGR is consumed by the emulator, not appended as text.
    fd.rendered_content.should eq ""
  ensure
    fd.try &.close
    win.try &.destroy
  end

  it "replays bytes fed before the first render" do
    win = headless_screen 40, 10
    fd = ansi_plane win
    fd.emulator.should be_nil # no resolved content size yet
    fd.feed "\e[36mpre"
    win.repaint

    x, y = content_origin fd
    cell_char(win, x, y).should eq 'p'
    cell_fg(win, x, y).should eq 0x00cdcd
  ensure
    fd.try &.close
    win.try &.destroy
  end

  it "honours cursor addressing and erases (the live-tail semantics)" do
    win = headless_screen 40, 10
    fd = ansi_plane win
    win.repaint
    fd.feed "first"
    win.repaint
    fd.feed "\e[2J\e[1;1Hsecond"
    win.repaint

    x, y = content_origin fd
    row_text(win, y, x..(x + 5)).should eq "second"
  ensure
    fd.try &.close
    win.try &.destroy
  end

  it "keeps painting inside its own region" do
    win = headless_screen 40, 10
    fd = ansi_plane win
    win.repaint
    # A line longer than the plane, on every row of a taller stream: nothing may
    # land left of, above, or below the widget's content rect.
    fd.feed "X" * 200
    win.repaint

    r = fd.contents_rect.not_nil!
    cell_char(win, r.left - 1, r.top).should eq ' '
    cell_char(win, r.x_end, r.top).should eq ' '
    cell_char(win, r.left, r.top - 1).should eq ' '
    cell_char(win, r.left, r.y_end).should eq ' '
    cell_char(win, r.x_end - 1, r.y_end - 1).should eq 'X'
  ensure
    fd.try &.close
    win.try &.destroy
  end

  it "resizes the emulator with the widget, keeping content at the top-left" do
    win = headless_screen 40, 10
    fd = ansi_plane win
    win.repaint
    r = fd.contents_rect.not_nil!
    em = fd.emulator.not_nil!
    em.cols.should eq r.width
    em.rows.should eq r.height

    fd.feed "\e[33mab"
    win.repaint
    fd.width = 30
    fd.height = 6
    win.repaint

    r2 = fd.contents_rect.not_nil!
    r2.width.should eq r.width + 10
    r2.height.should eq r.height + 2
    fd.emulator.not_nil!.cols.should eq r2.width
    fd.emulator.not_nil!.rows.should eq r2.height

    x, y = content_origin fd
    cell_char(win, x, y).should eq 'a'
    cell_fg(win, x, y).should eq 0xcdcd00
  ensure
    fd.try &.close
    win.try &.destroy
  end

  it "delegates scrollback to the emulator" do
    win = headless_screen 40, 10
    fd = ansi_plane win
    win.repaint
    em = fd.emulator.not_nil!
    # More lines than the page holds, so the top ones scroll off into the
    # emulator's scrollback (the widget itself holds no content lines).
    (em.rows + 2).times { |i| fd.feed "line#{i}\r\n" }
    win.repaint
    base = em.ybase
    base.should be > 0

    # At the live tail; scrolling all the way back shows the stream's first line.
    fd.scroll_percent.should eq 1.0
    fd.scroll(-base)
    win.repaint
    fd.scroll_percent.should eq 0.0
    x, y = content_origin fd
    row_text(win, y, x..(x + 4)).should eq "line0"

    # `#scroll_to` and `#reset_scroll` delegate too.
    fd.scroll_to 1
    win.repaint
    row_text(win, y, x..(x + 4)).should eq "line1"
    fd.reset_scroll
    win.repaint
    fd.scroll_percent.should eq 1.0
    row_text(win, y, x..(x + 4)).should eq "line#{base}"
  ensure
    fd.try &.close
    win.try &.destroy
  end

  it "claims the trailing cell of a wide glyph as a continuation" do
    # The window requires every 2-column lead to be followed by an in-region
    # continuation cell (the same invariant `Widget::Terminal#draw` upholds).
    win = Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new,
      error: IO::Memory.new, width: 40, height: 10, full_unicode: true)
    fd = ansi_plane win
    win.repaint
    fd.feed "中x"
    win.repaint

    x, y = content_origin fd
    cell_char(win, x, y).should eq '中'
    win.cell_rows[y][x + 1].continuation?.should be_true
    cell_char(win, x + 2, y).should eq 'x'
  ensure
    fd.try &.close
    win.try &.destroy
  end

  it "streams a real pipe through the emulator" do
    win = headless_screen 40, 10
    reader, writer = IO.pipe
    fd = Crysterm::Widget::LogFd.new(io: reader, mode: :ansi, parent: win,
      top: 1, left: 2, width: 20, height: 4)
    win.repaint
    x, y = content_origin fd

    writer.print "\e[32mgo"
    writer.flush
    # The reader fiber posts onto the render fiber, which repaints — so poll.
    wait_until { cell_char(win, x, y) == 'g' }
    cell_fg(win, x, y).should eq 0x00cd00
  ensure
    writer.try &.close
    fd.try &.close
    win.try &.destroy
  end
end

describe "Widget::LogFd :text mode (unchanged)" do
  it "is the default and builds no emulator" do
    win = headless_screen 40, 10
    fd = Crysterm::Widget::LogFd.new(io: IO::Memory.new(""), parent: win,
      top: 1, left: 2, width: 20, height: 4)
    fd.mode.text?.should be_true
    win.repaint
    fd.emulator.should be_nil
  ensure
    fd.try &.close
    win.try &.destroy
  end

  it "executes no escape sequence: control bytes stay literal text" do
    win = headless_screen 40, 10
    fd = Crysterm::Widget::LogFd.new(io: IO::Memory.new(""), parent: win,
      top: 1, left: 2, width: 20, height: 4)
    fd.feed "A\e[2J\e[1;1HB\e[Kend\n"
    # No erase, no cursor addressing: the sequences are just text on the line
    # (only the ESC byte itself is swallowed by the content renderer), where the
    # same stream in `:ansi` mode would show "Bend" alone, from column 0.
    fd.rendered_content.should eq "A[2J[1;1HB[Kend"
    win.repaint
    x, y = content_origin fd
    row_text(win, y, x..(x + 14)).should eq "A[2J[1;1HB[Kend"
  ensure
    fd.try &.close
    win.try &.destroy
  end

  it "still colours inline SGR through the normal content renderer" do
    # Unchanged pre-existing behaviour, asserted so the `:ansi` work can't
    # silently take it away: SGR runs in the appended text are styled by the
    # widget's own content pipeline (only the emulator-driven parts are new).
    win = headless_screen 40, 10
    fd = Crysterm::Widget::LogFd.new(io: IO::Memory.new(""), parent: win,
      top: 1, left: 2, width: 20, height: 4)
    fd.feed "\e[31;44mHi\e[0m\n"
    win.repaint

    x, y = content_origin fd
    row_text(win, y, x..(x + 1)).should eq "Hi"
    cell_fg(win, x, y).should eq 0xcd0000
    cell_fg(win, x + 2, y).should eq -1 # the SGR reset ends the run
  ensure
    fd.try &.close
    win.try &.destroy
  end
end
