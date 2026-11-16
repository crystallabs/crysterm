require "./spec_helper"

# An `IO` whose reads are fed from a channel, counting them: what the reader
# fiber of a `Widget::LogFd` has asked of a stream it does not own.
private class Bugs20ChunkIO < IO
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

describe Crysterm::TerminalEmulator do
  describe "C1 ST (0x9C) inside a string" do
    it "ends an OSC opened by C1 OSC and delivers its title" do
      em = emu(cols: 10)
      title = nil
      em.on_title { |t| title = t }
      em.feed "\u{9D}0;name\u{9C}Z"
      title.should eq "name"
      emu_row(em, 0).should eq "Z"
    end

    it "ends an OSC opened by ESC ]" do
      em = emu(cols: 10)
      title = nil
      em.on_title { |t| title = t }
      em.feed "\e]2;name\u{9C}Z"
      title.should eq "name"
      emu_row(em, 0).should eq "Z"
    end

    it "ends a DCS string, whose payload stays discarded" do
      em = emu(cols: 10)
      title = nil
      em.on_title { |t| title = t }
      em.feed "\eP0;payload\u{9C}Z"
      title.nil?.should be_true
      emu_row(em, 0).should eq "Z"
    end
  end
end

describe Crysterm::Neovim::Keys do
  it "names the control characters past Ctrl-Z by their own key" do
    Crysterm::Neovim::Keys.notation('\u001c', nil).should eq "<C-Bslash>"
    Crysterm::Neovim::Keys.notation('\u001d', nil).should eq "<C-]>"
    Crysterm::Neovim::Keys.notation('\u001e', nil).should eq "<C-^>"
    Crysterm::Neovim::Keys.notation('\u001f', nil).should eq "<C-_>"
    Crysterm::Neovim::Keys.notation('\u001a', nil).should eq "<C-z>"
  end
end

describe Crysterm::Widget::LogFd do
  it "stops reading a caller-supplied IO once closed" do
    win = headless_screen(80, 24)
    chunks = Channel(Bytes).new(4)
    io = Bugs20ChunkIO.new chunks
    fd = Crysterm::Widget::LogFd.new(io: io, parent: win, top: 0, left: 0, width: 40, height: 10)
    # The reader fiber is parked in its first read.
    wait_until { io.reads == 1 }
    fd.close
    chunks.send "a\n".to_slice
    chunks.send "b\n".to_slice
    became?(100.milliseconds) { io.reads > 1 }.should be_false
  ensure
    chunks.try &.close
    win.try &.destroy
  end
end

describe Crysterm::Neovim::Client do
  it "ends a process whose output is not msgpack" do
    # 0xC1 is the one byte that starts no msgpack value.
    script = File.tempfile("crysterm-fake-nvim") do |f|
      f.print "#!/bin/sh\nprintf '\\301'\nexec sleep 30\n"
    end
    File.chmod script.path, 0o755
    client = Crysterm::Neovim::Client.new executable: script.path
    wait_until(5.seconds) { !client.running? }
    client.running?.should be_false
  ensure
    client.try &.close(grace: 100.milliseconds)
    script.try &.delete
  end
end
