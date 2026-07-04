require "./spec_helper"

include Crysterm

# Specs for `Widget::LogFd` (notcurses `ncfdplane`/`ncsubproc` parity).
#
# The value-add is deterministic and headless-testable: the pure line/UTF-8
# boundary splitter (`.extract_lines`), the synchronous append path (`#feed`),
# and the lifecycle wiring. The live path — a background reader fiber pumping a
# real fd/subprocess and marshalling lines onto the render fiber — needs a
# running render loop to drain `Window#post`, so it is exercised by the runnable
# demo (`tests/misc/fd_plane.cr`), not here (mirroring how the Terminal PTY path
# is demo-verified, not unit-tested).

private def headless_window
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: 24)
end

# Build a plane over an already-drained IO so the reader fiber (started eagerly
# because we pass a parent) finds EOF immediately and never races `#feed`.
private def plane(win)
  Crysterm::Widget::LogFd.new(io: IO::Memory.new(""), parent: win,
    top: 0, left: 0, width: 40, height: 10)
end

alias LogFd = Crysterm::Widget::LogFd

describe "Widget::LogFd.extract_lines" do
  it "splits on newline and carries the trailing partial line" do
    lines, carry = LogFd.extract_lines(Bytes.new(0), "a\nb\nc".to_slice)
    lines.should eq ["a", "b"]
    String.new(carry).should eq "c" # 'c' has no terminator yet
  end

  it "joins a carried partial line with the next chunk" do
    lines1, carry1 = LogFd.extract_lines(Bytes.new(0), "hel".to_slice)
    lines1.should be_empty
    lines2, carry2 = LogFd.extract_lines(carry1, "lo\nrest".to_slice)
    lines2.should eq ["hello"]
    String.new(carry2).should eq "rest"
  end

  it "strips a trailing CR (CRLF streams)" do
    lines, carry = LogFd.extract_lines(Bytes.new(0), "a\r\nb\r\n".to_slice)
    lines.should eq ["a", "b"]
    carry.size.should eq 0
  end

  it "preserves empty lines" do
    lines, _ = LogFd.extract_lines(Bytes.new(0), "\n\nx\n".to_slice)
    lines.should eq ["", "", "x"]
  end

  it "never splits a multibyte UTF-8 glyph at a chunk boundary" do
    # '中' is 0xE4 0xB8 0xAD; deliver it one byte at a time across three chunks,
    # the last carrying the terminating newline.
    _, c1 = LogFd.extract_lines(Bytes.new(0), Bytes[0xE4])
    _, c2 = LogFd.extract_lines(c1, Bytes[0xB8])
    lines, c3 = LogFd.extract_lines(c2, Bytes[0xAD, 0x0A])
    lines.should eq ["中"]
    c3.size.should eq 0
  end

  it "handles empty chunks and empty carry" do
    lines, carry = LogFd.extract_lines(Bytes.new(0), Bytes.new(0))
    lines.should be_empty
    carry.size.should eq 0
  end
end

describe "Widget::LogFd#feed" do
  it "appends complete lines to the log content" do
    win = headless_window
    fd = plane win
    fd.feed "one\ntwo\n"
    fd.get_content.should eq "one\ntwo"
  ensure
    fd.try &.close
    win.try &.destroy
  end

  it "carries a partial line across feeds until its newline arrives" do
    win = headless_window
    fd = plane win
    fd.feed "par"
    fd.get_content.should eq "" # nothing complete yet
    fd.feed "tial\n"
    fd.get_content.should eq "partial"
  ensure
    fd.try &.close
    win.try &.destroy
  end

  it "reassembles a multibyte glyph fed in byte-sized pieces" do
    win = headless_window
    fd = plane win
    fd.feed Bytes[0xE4]
    fd.feed Bytes[0xB8, 0xAD, 0x0A]
    fd.get_content.should eq "中"
  ensure
    fd.try &.close
    win.try &.destroy
  end

  it "flush_carry emits a buffered partial line as a final line" do
    win = headless_window
    fd = plane win
    fd.feed "no newline here"
    fd.get_content.should eq ""
    fd.flush_carry
    fd.get_content.should eq "no newline here"
    fd.flush_carry # idempotent when empty
    fd.get_content.should eq "no newline here"
  ensure
    fd.try &.close
    win.try &.destroy
  end
end

describe "Widget::LogFd lifecycle" do
  it "wraps a caller IO with no subprocess" do
    win = headless_window
    fd = plane win
    fd.process.should be_nil
    fd.closed?.should be_false
  ensure
    fd.try &.close
    win.try &.destroy
  end

  it "spawns a subprocess for the command form and reaps it on close" do
    win = headless_window
    fd = Crysterm::Widget::LogFd.new("true", parent: win,
      top: 0, left: 0, width: 40, height: 10)
    fd.process.should_not be_nil
    fd.closed?.should be_false
    fd.close
    fd.closed?.should be_true
    fd.close # idempotent
    fd.closed?.should be_true
  ensure
    win.try &.destroy
  end

  it "propagates a spawn failure for a missing command" do
    win = headless_window
    expect_raises(Exception) do
      Crysterm::Widget::LogFd.new("this-command-does-not-exist-xyz", parent: win)
    end
  ensure
    win.try &.destroy
  end
end
