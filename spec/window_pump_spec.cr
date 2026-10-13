require "./spec_helper"

include Crysterm

# `Window#pump`: an IO read line by line on a reader fiber, each line
# handed to the block on the render fiber, then `done` with the error
# that ended the read (`nil` at end of input). `TextEdit#stream_markdown`
# is the Markdown case on top of it.

# Yields one line, then fails like a broken pipe.
private class BreakingIO < IO
  @pending = "first\n".to_slice

  def read(slice : Bytes) : Int32
    raise IO::Error.new("broken pipe") if @pending.empty?
    n = Math.min(slice.size, @pending.size)
    slice.copy_from @pending[0, n]
    @pending += n
    n
  end

  def write(slice : Bytes) : Nil
  end
end

# Waits for the stream's `done`, failing the example on a hang.
# Hands the reader what is fed to it, blocking between lines.
private class FedIO < IO
  @lines = Channel(String).new
  @pending = Bytes.empty

  def feed(line : String) : Nil
    @lines.send line
  end

  def read(slice : Bytes) : Int32
    @pending = @lines.receive.to_slice if @pending.empty?
    n = Math.min(slice.size, @pending.size)
    slice.copy_from @pending[0, n]
    @pending += n
    n
  end

  def write(slice : Bytes) : Nil
  end
end

private def wait(done : Channel(IO::Error?)) : IO::Error?
  select
  when e = done.receive
    e
  when timeout(2.seconds)
    fail "the stream never finished"
  end
end

describe "Window#pump" do
  it "hands each line, terminator kept, to the block in order, then done with nil" do
    s = headless_screen(default_quit_keys: true)
    lines = [] of String
    done = Channel(IO::Error?).new
    s.pump(IO::Memory.new("one\ntwo\nlast"), done: ->(e : IO::Error?) { done.send e; nil }) { |l| lines << l }
    wait(done).should be_nil
    lines.should eq ["one\n", "two\n", "last"]
    s.destroy
  end

  it "passes the IO error that cut the stream short to done, after the lines read" do
    s = headless_screen(default_quit_keys: true)
    lines = [] of String
    done = Channel(IO::Error?).new
    s.pump(BreakingIO.new, done: ->(e : IO::Error?) { done.send e; nil }) { |l| lines << l }
    error = wait(done)
    error.should be_a IO::Error
    error.try(&.message).should eq "broken pipe"
    lines.should eq ["first\n"]
    s.destroy
  end

  it "needs no done callback" do
    s = headless_screen(default_quit_keys: true)
    seen = Channel(String).new
    s.pump(IO::Memory.new("only\n")) { |l| seen.send l }
    select
    when l = seen.receive
      l.should eq "only\n"
    when timeout(2.seconds)
      fail "the line never arrived"
    end
    s.destroy
  end

  it "ends the read and runs done at once when the window is destroyed mid-stream" do
    s = headless_screen(default_quit_keys: true)
    io = FedIO.new
    lines = [] of String
    done = Channel(IO::Error?).new
    s.pump(io, done: ->(e : IO::Error?) { done.send e; nil }) { |l| lines << l }
    io.feed "shown\n"
    wait_until { lines == ["shown\n"] }
    s.destroy
    # No render fiber is left to show the next line: the reader stops at it,
    # and done runs on the reader fiber, with the stream not in error.
    io.feed "dropped\n"
    wait(done).should be_nil
    lines.should eq ["shown\n"]
  end

  it "runs a done posted but not yet run when the window is destroyed, once" do
    s = headless_screen(default_quit_keys: true)
    ran = 0
    # A job holding the render fiber keeps it from draining the queue, so
    # the done the reader posts behind it is still queued when the window
    # goes.
    gate = Channel(Nil).new
    s.post { gate.receive }
    lines = [] of String
    s.pump(IO::Memory.new("line\n"), done: ->(_e : IO::Error?) { ran += 1; nil }) { |l| lines << l }
    wait_until { ran == 0 && s.@pump_releases.size == 1 }
    s.destroy
    ran.should eq 1
    # The held render fiber, let go, runs none of the jobs left: they went
    # with the window.
    gate.send nil
    3.times { Fiber.yield }
    lines.should be_empty
    ran.should eq 1
  end
end

describe "TextEdit#stream_markdown" do
  it "appends the Markdown as it arrives, following the tail, and flushes at the end" do
    s = headless_screen(40, 8, default_quit_keys: true)
    tb = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: 40, height: 8
    s.repaint
    tb.follow_tail?.should be_false
    done = Channel(IO::Error?).new
    tb.stream_markdown(IO::Memory.new("# Title\n\nfirst paragraph\n\nlast paragraph"), ->(e : IO::Error?) { done.send e; nil })
    tb.follow_tail?.should be_true
    wait(done).should be_nil
    tb.document.plain_text.should contain "first paragraph"
    # The unterminated last paragraph was flushed by the end of the stream.
    tb.document.plain_text.should contain "last paragraph"
    s.destroy
  end
end
