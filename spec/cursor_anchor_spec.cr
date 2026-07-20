require "./spec_helper"

include Crysterm

# A trivial anchor with a fixed cursor cell, to exercise the base placement math
# independently of any host.
private class FixedAnchor < Crysterm::CursorAnchor
  def initialize(@pos : {Int32, Int32})
  end

  def cursor_pos : {Int32, Int32}
    @pos
  end
end

describe Crysterm::CursorAnchor do
  it "computes cursor_row/col and relative placement" do
    a = FixedAnchor.new({7, 3})
    a.cursor_row.should eq 7
    a.cursor_col.should eq 3
    # Two up, two left.
    a.relative(-2, -2).should eq({5, 1})
    # The line directly below (drop-down completer position).
    a.relative(1, 0).should eq({8, 3})
  end
end

describe Crysterm::TerminalCursorAnchor do
  it "falls back when the terminal does not answer (headless)" do
    screen = Crysterm::Screen.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 80, height: 24)
    anchor = Crysterm::TerminalCursorAnchor.new(screen, fallback: {4, 0})
    # No real tty behind the memory IO, so report_cursor yields nil -> fallback.
    anchor.cursor_pos.should eq({4, 0})
  end
end

describe Crysterm::WidgetCursorAnchor do
  it "translates the emulator cursor into the owning window's coordinate space" do
    win = Crysterm::Window.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 80, height: 24, default_quit_keys: false)
    term = Crysterm::Widget::Terminal.new(
      parent: win, top: 3, left: 5, width: 40, height: 10)
    win.repaint

    anchor = Crysterm::WidgetCursorAnchor.new(term)
    row, col = anchor.cursor_pos
    # The anchor lands within the terminal widget's on-screen content area,
    # regardless of where the emulator cursor currently sits.
    row.should be >= term.atop + term.itop
    col.should be >= term.aleft + term.ileft
    row.should be < term.atop + term.itop + 10
  end
end
