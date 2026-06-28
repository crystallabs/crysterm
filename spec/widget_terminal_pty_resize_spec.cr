require "./spec_helper"

include Crysterm

# Regression spec for `Crysterm::Pty#resize`.
#
# `#resize` issues the `TIOCSWINSZ` ioctl so the child program learns about a
# new terminal geometry. That request number is platform-specific (BSD/macOS
# encode it via `_IOW('t', 103, struct winsize)` = 0x80087467, Linux uses the
# flat 0x5414) — exactly like the term-screen shard's read-side
# `LibC::TIOCGWINSZ`. The constant used to be hardcoded to the Linux value, so
# on macOS/BSD the ioctl number was wrong and the resize silently did nothing.
#
# Here we open a real PTY, resize it, and read the geometry back from the master
# fd with `TIOCGWINSZ` (which reflects the line discipline's current winsize).
# With the wrong (Linux) request on macOS the set is a no-op and the read-back
# stays at the initial 80x24; with the correct platform value it reports 100x40.
describe Crysterm::Pty do
  describe "#resize" do
    it "propagates the new geometry to the PTY (correct TIOCSWINSZ per platform)" do
      # A harmless, long-lived child that just sits on the slave PTY.
      pty = Crysterm::Pty.new("sleep", ["30"], cols: 80, rows: 24)
      begin
        pty.resize(100, 40)

        ws = LibC::Winsize.new
        rc = LibC.ioctl(pty.master.fd, LibC::TIOCGWINSZ, pointerof(ws))
        rc.should eq(0)
        ws.ws_col.should eq(100)
        ws.ws_row.should eq(40)
      ensure
        pty.kill
      end
    end
  end
end
