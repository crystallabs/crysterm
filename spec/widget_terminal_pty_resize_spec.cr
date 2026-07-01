require "./spec_helper"

include Crysterm

# Regression spec for `Crysterm::Pty#resize`.
#
# `#resize` issues the `TIOCSWINSZ` ioctl. The request number is
# platform-specific (BSD/macOS: `_IOW('t', 103, struct winsize)` = 0x80087467;
# Linux: flat 0x5414) — same as read-side `LibC::TIOCGWINSZ`. It used to be
# hardcoded to the Linux value, silently no-oping the resize on macOS/BSD.
#
# Opens a real PTY, resizes it, and reads the geometry back via `TIOCGWINSZ`:
# wrong (Linux) request on macOS leaves it at 80x24, correct value reports 100x40.
describe Crysterm::Pty do
  describe "#resize" do
    it "propagates the new geometry to the PTY (correct TIOCSWINSZ per platform)" do
      # Long-lived child on the slave PTY.
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
