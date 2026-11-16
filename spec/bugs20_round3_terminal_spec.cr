require "./spec_helper"

# An `IO` whose reads are fed from a channel, counting them.
private class Round3ChunkIO < IO
  getter reads = 0

  def initialize(@chunks : Channel(Bytes))
  end

  def read(slice : Bytes) : Int32
    @reads += 1
    chunk = @chunks.receive? || return 0
    chunk.copy_to slice
    chunk.size
  end

  def write(slice : Bytes) : Nil
  end
end

# A reply sink that fails, as a PTY whose child has gone does.
private class Round3BrokenSink < IO
  def read(slice : Bytes) : Int32
    0
  end

  def write(slice : Bytes) : Nil
    raise IO::Error.new("sink gone")
  end
end

# L0..L5 on rows 0..5 of a 4x6 grid, cursor left on the last row.
private def six_rows
  em = emu(4, 6)
  6.times { |i| em.feed "\e[#{i + 1};1HL#{i}" }
  em
end

describe Crysterm::TerminalEmulator do
  describe "shrinking the rows" do
    it "keeps the cursor line, moving the top lines into the scrollback" do
      em = six_rows
      em.resize(4, 3)
      emu_row(em, 0).should eq "L3"
      emu_row(em, 1).should eq "L4"
      emu_row(em, 2).should eq "L5"
      em.cursor_y.should eq 2
      em.ybase.should eq 3
      em.ydisp.should eq 3
      em.lines.size.should eq 6
      em.lines[0].map(&.char).join.rstrip.should eq "L0"
    end

    it "drops the rows below the cursor before taking any from the top" do
      em = six_rows
      em.feed "\e[4;1H" # cursor on L3: two rows below it
      em.resize(4, 3)
      emu_row(em, 0).should eq "L1"
      emu_row(em, 1).should eq "L2"
      emu_row(em, 2).should eq "L3"
      em.cursor_y.should eq 2
      em.ybase.should eq 1
      # A line feed on the last row brings up a blank, not a dropped row.
      em.feed "\n"
      emu_row(em, 2).should eq ""
    end

    it "takes nothing from the top while the cursor stays inside" do
      em = six_rows
      em.feed "\e[2;1H"
      em.resize(4, 3)
      emu_row(em, 0).should eq "L0"
      emu_row(em, 2).should eq "L2"
      em.cursor_y.should eq 1
      em.ybase.should eq 0
    end

    it "moves a saved cursor up with its page" do
      em = six_rows
      em.feed "\e7" # saved on row 5
      em.resize(4, 3)
      em.feed "\e[H\e8"
      em.cursor_y.should eq 2
    end

    it "discards the top lines of the alternate page, which has no scrollback" do
      em = six_rows
      em.feed "\e[?1049h"
      6.times { |i| em.feed "\e[#{i + 1};1HA#{i}" }
      em.resize(4, 3)
      emu_row(em, 0).should eq "A3"
      emu_row(em, 2).should eq "A5"
      em.cursor_y.should eq 2
      em.ybase.should eq 0
      em.lines.size.should eq 3
    end

    it "keeps the main page's cursor line while the alternate page is shown" do
      em = six_rows
      em.feed "\e[?1049h"
      em.resize(4, 3)
      em.feed "\e[?1049l"
      emu_row(em, 0).should eq "L3"
      emu_row(em, 2).should eq "L5"
      em.cursor_y.should eq 2
      em.ybase.should eq 3
    end
  end

  describe "DECSET 1049" do
    it "saves the cursor and clears the alternate page when already on it" do
      em = emu(10, 4)
      em.feed "\e[?47h\e[2;3HX"
      em.feed "\e[?1049h"
      em.alt_active?.should be_true
      emu_row(em, 1).should eq ""
      em.feed "\e[H\e8"
      em.cursor_y.should eq 1
      em.cursor_x.should eq 3
    end

    it "restores the cursor on reset when not on the alternate page" do
      em = emu(10, 4)
      em.feed "\e[2;3H\e7\e[4;5H"
      em.feed "\e[?1049l"
      em.alt_active?.should be_false
      em.cursor_y.should eq 1
      em.cursor_x.should eq 2
    end

    it "restores the cursor it saved after a 1047 reset already left the page" do
      em = emu(10, 4)
      em.feed "main\e[2;3H\e[?1049h\e[4;5H\e[?1047l"
      em.alt_active?.should be_false
      em.cursor_y.should eq 3
      em.feed "\e[?1049l"
      em.cursor_y.should eq 1
      em.cursor_x.should eq 2
      emu_row(em, 0).should eq "main"
    end

    it "leaves a page entered with 47 and restores the main page's cursor" do
      em = emu(10, 4)
      em.feed "main\e[2;3H\e7\e[?47h\e[4;5Halt"
      em.feed "\e[?1049l"
      em.alt_active?.should be_false
      emu_row(em, 0).should eq "main"
      em.cursor_y.should eq 1
      em.cursor_x.should eq 2
    end
  end

  describe "a reply sink that raises" do
    it "leaves the parser reading what follows as text" do
      em = emu(10, 4)
      em.output = Round3BrokenSink.new
      expect_raises(IO::Error) { em.feed "\e[6n" }
      em.output = nil
      em.feed "AB"
      emu_row(em, 0).should eq "AB"
    end
  end
end

describe Crysterm::Pty do
  describe "#write" do
    it "returns at once for a child that is not reading" do
      pty = Crysterm::Pty.new("sleep", ["30"])
      pty.write("x" * (1 << 20)).should be_true
      pty.write_backlog.should eq(1 << 20)
      pty.writing?.should be_true
      pty.kill(5.milliseconds)
      pty.write_backlog.should eq 0
      pty.write("more").should be_false
      wait_until { !pty.writing? }
      pty.reap
    ensure
      pty.try &.kill
    end

    it "refuses input once the backlog limit is waiting" do
      pty = Crysterm::Pty.new("sleep", ["30"])
      pty.write(Bytes.new(Crysterm::Pty::WRITE_BACKLOG_LIMIT, 'x'.ord.to_u8)).should be_true
      pty.write("y").should be_false
      pty.kill(5.milliseconds)
      wait_until { !pty.writing? }
      pty.reap
    ensure
      pty.try &.kill
    end

    it "delivers a large input whole and in order" do
      pty = Crysterm::Pty.new("sh", ["-c", "stty raw -echo; printf ready; cat"])
      got = IO::Memory.new
      spawn do
        buf = Bytes.new 8192
        loop do
          n = pty.master.read buf
          break if n == 0
          got.write buf[0, n]
        rescue IO::Error
          break
        end
      end
      wait_until(5.seconds) { got.to_s.includes?("ready") }

      chunks = Array.new(20) { |c| String.build { |io| 1000.times { |i| io << "line " << c << '.' << i << '\n' } } }
      expected = chunks.join
      chunks.each { |chunk| pty.write(chunk).should be_true }
      wait_until(10.seconds) { got.size >= 5 + expected.bytesize }
      got.to_s.should eq "ready" + expected
      pty.writing?.should be_false
    ensure
      pty.try &.kill(5.milliseconds)
    end
  end
end

describe Crysterm::Widget::LogFd do
  it "kills a child that ignores SIGTERM on close" do
    win = headless_screen(80, 24)
    fd = Crysterm::Widget::LogFd.new("sh", ["-c", "trap '' TERM; echo ready; while :; do sleep 0.1; done"],
      parent: win, top: 0, left: 0, width: 40, height: 10)
    exited = 0
    fd.on(Crysterm::Event::ProcessExited) { exited += 1 }
    wait_until(5.seconds) { fd.rendered_content.includes?("ready") }

    fd.close(20.milliseconds)
    wait_until(5.seconds) { exited == 1 }
  ensure
    fd.try &.process.try { |p| p.signal(Signal::KILL) rescue nil }
    win.try &.destroy
  end

  it "holds what it reads while removed from its window and shows it once back" do
    win = headless_screen(80, 24)
    box = Crysterm::Widget::Box.new parent: win, top: 0, left: 0, width: 40, height: 10
    chunks = Channel(Bytes).new
    io = Round3ChunkIO.new chunks
    fd = Crysterm::Widget::LogFd.new(io: io, parent: box, top: 0, left: 0, width: 40, height: 10)
    chunks.send "one\n".to_slice
    wait_until { fd.rendered_content.includes?("one") }

    box.remove fd
    fd.window?.nil?.should be_true
    chunks.send "two\n".to_slice
    # Lets the reader take the chunk as far as it goes with no window.
    Fiber.yield
    io.reads.should eq 2

    box.append fd
    wait_until { fd.rendered_content.includes?("two") }
  ensure
    fd.try &.close
    chunks.try &.close
    win.try &.destroy
  end
end
