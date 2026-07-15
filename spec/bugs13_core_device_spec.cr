require "./spec_helper"

include Crysterm

# Regression specs for BUGS13 core findings C6, C8, C12, C15, C25
# (src/window.cr `#screen=`/`#switch_terminal`, src/screen.cr `#reconnected`,
# src/window_connection.cr `#connect`):
#
# C6  — `switch_terminal` must carry the explicit-size PIN STATE, not pin the
#       current size unconditionally: an unpinned window force-pinned both
#       axes, so the replacement stopped tracking terminal resizes forever.
# C8  — `Screen#reconnected` must carry the explicit pins too, or a reattached
#       inline window (pinned height) balloons to the full terminal height.
# C12 — `Window#screen=` must size (`adopt_terminal_size`) and probe an
#       adopted device: a fresh `Screen` stays at its 1×1 construction default
#       until the first SIGWINCH otherwise.
# C15 — reattaching an inline window must re-capture the anchor row against
#       the NEW terminal (the old terminal's cursor row is meaningless there).
# C25 — reattach must re-detect cell pixel geometry on the new device (pixel
#       mouse decoding / CSS px lengths read it); folded into the C12 fix in
#       `#screen=`, before any input listening starts.

private def b13d_window(w = 40, h = 10)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

# Records `detect_cell_geometry` invocations (C25) without touching a tty.
private class B13GeomProbeScreen < Crysterm::Screen
  getter geom_calls = 0

  def detect_cell_geometry : Nil
    @geom_calls += 1
  end
end

describe "BUGS13 C12: Window#screen= sizes an adopted fresh device" do
  it "adopts the terminal size instead of rendering 1x1" do
    w = b13d_window
    fresh = Crysterm::Screen.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
    # A fresh Screen defers sizing: it is 1x1 until told otherwise.
    fresh.width.should eq 1
    fresh.height.should eq 1

    w.screen = fresh
    # The adopted device sized itself from its own tput (which read the
    # terminal / fell back to a sane default) — not the 1x1 construction stub.
    w.awidth.should eq fresh.tput.screen.width
    w.aheight.should eq fresh.tput.screen.height
    w.awidth.should be > 1
    # The cell buffers follow the adopted size.
    w.lines.size.should eq w.aheight
    w.lines[0].size.should eq w.awidth

    w.destroy
  end

  it "honors pinned axes on the adopted device" do
    w = b13d_window
    pinned = Crysterm::Screen.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 33, height: 7)
    w.screen = pinned
    w.awidth.should eq 33
    w.aheight.should eq 7
    w.destroy
  end
end

describe "BUGS13 C25: reattach re-detects cell pixel geometry" do
  it "screen= calls detect_cell_geometry on the adopted device" do
    w = b13d_window
    probe = B13GeomProbeScreen.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 40, height: 10)
    w.screen = probe
    probe.geom_calls.should eq 1
    w.destroy
  end
end

describe "BUGS13 C8: reconnect keeps explicit-size pins" do
  it "a reattached pinned window keeps its size (inline contract)" do
    w = b13d_window(40, 5)
    w.screen.explicit_width?.should be_true
    w.screen.explicit_height?.should be_true

    w.disconnect
    w.connect(IO::Memory.new, IO::Memory.new)

    # The rebuilt device carried the pins; the size did not balloon to the
    # terminal's.
    w.screen.explicit_width?.should be_true
    w.screen.explicit_height?.should be_true
    w.awidth.should eq 40
    w.aheight.should eq 5

    w.destroy
  end

  it "reconnected() carries per-axis pins and sizes unpinned axes from the terminal" do
    s = Crysterm::Screen.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      height: 5) # only height pinned (the inline shape)
    s2 = s.reconnected(IO::Memory.new, IO::Memory.new)
    s2.explicit_width?.should be_false
    s2.explicit_height?.should be_true
    s2.height.should eq 5
    s2.width.should eq s2.tput.screen.width
  end
end

describe "BUGS13 C6: switch_terminal carries pin state" do
  it "keeps explicitly-pinned sizes pinned" do
    w = b13d_window(40, 10)
    w2 = w.switch_terminal "xterm"
    begin
      w2.screen.explicit_width?.should be_true
      w2.screen.explicit_height?.should be_true
      w2.awidth.should eq 40
      w2.aheight.should eq 10
    ensure
      w2.destroy
    end
  end

  it "does not pin an unpinned window's axes (still tracks resizes)" do
    # No width/height passed: the device follows the terminal.
    w = Crysterm::Window.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      default_quit_keys: false)
    w.screen.explicit_width?.should be_false
    w.screen.explicit_height?.should be_false

    w2 = w.switch_terminal "xterm"
    begin
      # Pre-fix, the current size was passed as plain Int32s, pinning both
      # axes: `resize`/`adopt_terminal_size` then no-op'd forever and the
      # replacement window froze at the moment-of-switch size.
      w2.screen.explicit_width?.should be_false
      w2.screen.explicit_height?.should be_false
      w2.screen.resize 55, 13
      w2.awidth.should eq 55
      w2.aheight.should eq 13
    ensure
      w2.destroy
    end
  end
end

describe "BUGS13 C15: reattach re-anchors an inline window" do
  it "re-captures the anchor row on the new device instead of reusing the old one" do
    w = Crysterm::Window.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 40, height: 4, alternate: false, default_quit_keys: false)
    # Simulate having been anchored partway down the OLD terminal.
    w.anchor_row = 7
    w.render_row_offset.should be >= 0

    w.disconnect
    w.connect(IO::Memory.new, IO::Memory.new)

    # The new (headless) terminal answers no cursor query: the re-capture
    # falls back to row 0 rather than keeping the stale row-7 anchor from the
    # previous terminal.
    w.anchor_row.should eq 0
    w.render_row_offset.should eq 0

    w.destroy
  end
end
