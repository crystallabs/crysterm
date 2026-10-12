require "./spec_helper"

# `Terminal.open_tty`: a spawned window's TTY is opened non-blocking, so its
# input fiber waiting for a key parks in the event loop instead of stalling
# the process (on macOS `File.open` opens every path blocking).
describe "Crysterm::Terminal.open_tty" do
  it "opens a TTY whose reads leave the other fibers running" do
    master_fd = uninitialized LibC::Int
    slave_fd = uninitialized LibC::Int
    Crysterm::Pty::LibUtil.openpty(pointerof(master_fd), pointerof(slave_fd),
      Pointer(LibC::Char).null, Pointer(Void).null, Pointer(LibC::Winsize).null).should eq 0
    master = IO::FileDescriptor.new master_fd
    slave = IO::FileDescriptor.new slave_fd
    path = Crysterm::Screen.terminal_path(slave).not_nil!

    input = Crysterm::Terminal.open_tty(path, LibC::O_RDONLY)
    output = Crysterm::Terminal.open_tty(path, LibC::O_WRONLY)
    begin
      IO::FileDescriptor.get_blocking(input.fd).should be_false
      IO::FileDescriptor.get_blocking(output.fd).should be_false

      got = Channel(Char?).new(1)
      spawn { got.send input.read_char }
      # The reader is parked on the TTY; this fiber still runs.
      ticked = false
      spawn { ticked = true }
      sleep 20.milliseconds
      ticked.should be_true

      master.print "q\n" # a line: the TTY is in canonical mode
      master.flush
      select
      when char = got.receive
        char.should eq 'q'
      when timeout(2.seconds)
        fail "the read never returned"
      end
    ensure
      input.close
      output.close
      slave.close
      master.close
    end
  end
end
