require "./spec_helper"
require "socket"

include Crysterm

# Regression specs for BUGS15 findings #72, #79, #80 (Window device-migration
# paths in src/window.cr `#screen=` / `#switch_terminal`):
#
# #72 — `#screen=` must close and clear the spawned emulator window (`@window`)
#       and drop IO ownership when leaving the old device: otherwise the stale
#       emulator's close-watcher later fires `on_window_closed`, passes all
#       guards, and disconnects the window from its NEW, healthy device —
#       with `@owns_io` still true, even closing the new device's fds.
# #79 — `#screen=` departing a SHARED device must hand the departing window's
#       pinned cursor/title state back to the surviving sibling
#       (`reassert_sibling_terminal_state`), mirroring `#disconnect`.
# #80 — `#switch_terminal` must carry `alternate`/`auto_grow`/`max_height`/
#       `padding`/`cursor` to the replacement window: an inline window must
#       not silently come back as a full-screen alt-buffer window.

private def b15m_window(w = 30, h = 8)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

private def b15m_screen(w = 30, h = 8)
  Crysterm::Screen.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h)
end

# A headless stand-in for a spawned emulator window: a real socketpair (so the
# close-watcher fiber has a live rendezvous socket to block on) plus a benign
# process and /dev/null tty fds. Returns the window and the "emulator side" of
# the socket.
private def b15m_fake_emulator
  local, remote = UNIXSocket.pair
  process = Process.new("sleep", ["30"])
  win = Crysterm::Terminal::Window.new(
    process, local, File.tempname("b15m", ".sock"), "/dev/null",
    File.open("/dev/null", "r"), File.open("/dev/null", "w"))
  {win, remote}
end

describe "BUGS15 #72: screen= retires the old device's spawned window" do
  it "closes and clears @window; the stale watcher cannot disconnect the new device" do
    a = b15m_window
    win, remote = b15m_fake_emulator
    begin
      a.adopt_window win
      a.window.should eq win

      s2 = b15m_screen
      a.screen = s2

      # The spawned-window reference was cleared with the old device...
      a.window.should be_nil
      # ...and the emulator itself was closed: its side of the rendezvous
      # socket sees EOF (pre-fix this would time out — the window leaked open).
      remote.read_timeout = 2.seconds
      begin
        remote.gets.should be_nil
      rescue IO::TimeoutError
        fail "stale emulator window was left open (rendezvous socket not closed)"
      end

      # Let the watcher fiber observe the EOF and run `on_window_closed`: its
      # `@window == win` guard must reject the stale notification instead of
      # disconnecting the window from its NEW device.
      sleep 50.milliseconds
      a.connected?.should be_true
      s2.input.as(IO::Memory).closed?.should be_false
      s2.output.as(IO::Memory).closed?.should be_false
    ensure
      remote.close rescue nil
      win.close
      a.destroy
    end
  end

  it "drops the old device's IO ownership so a later disconnect spares the new fds" do
    a = b15m_window
    win, remote = b15m_fake_emulator
    begin
      # `adopt_window` marks the (old) device's IO as owned by this window.
      a.adopt_window win

      s2 = b15m_screen
      a.screen = s2

      # A real disconnect now: pre-fix `@owns_io` was still true from the OLD
      # spawned window, so this closed the NEW screen's fds.
      a.disconnect
      s2.input.as(IO::Memory).closed?.should be_false
      s2.output.as(IO::Memory).closed?.should be_false
    ensure
      remote.close rescue nil
      win.close
      a.destroy
    end
  end
end

describe "BUGS15 #79: screen= re-asserts sibling terminal state on a shared device" do
  it "hands the surviving sibling's cursor/title back to the old terminal" do
    shared_out = IO::Memory.new
    s = Crysterm::Screen.new(
      input: IO::Memory.new, output: shared_out, error: IO::Memory.new,
      width: 30, height: 8)
    a = Crysterm::Window.new(screen: s, default_quit_keys: false)
    b = Crysterm::Window.new(screen: s, default_quit_keys: false)
    begin
      b.title = "SIBLING-B"
      shared_out.clear
      shared_out.to_s.should_not contain "SIBLING-B"

      a.screen = b15m_screen

      # The departing window left a shared device: the sibling's title (and
      # cursor state) was re-asserted on the old terminal instead of the
      # departing window's values being stranded there forever.
      shared_out.to_s.should contain "SIBLING-B"
      # And the shared device was NOT torn down under the sibling.
      b.connected?.should be_true
      s.input.as(IO::Memory).closed?.should be_false
    ensure
      a.destroy
      b.destroy
    end
  end
end

describe "BUGS15 #80: switch_terminal keeps surface mode and chrome knobs" do
  it "carries alternate/auto_grow/max_height/padding/cursor to the replacement" do
    w = Crysterm::Window.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 30, height: 5, alternate: false, auto_grow: true, max_height: 12,
      padding: 1, default_quit_keys: false)
    w.cursor.shape = Tput::CursorShape::Underline
    w.cursor.blink = true

    w2 = w.switch_terminal "xterm"
    begin
      # Pre-fix the replacement defaulted to `alternate: true` — a full-screen
      # alt-buffer takeover replacing an inline window.
      w2.alternate?.should be_false
      w2.auto_grow?.should be_true
      w2.max_height.should eq 12
      {w2.padding.left, w2.padding.top, w2.padding.right, w2.padding.bottom}
        .should eq({1, 1, 1, 1})
      w2.cursor.shape.should eq Tput::CursorShape::Underline
      w2.cursor.blink.should be_true
    ensure
      w2.destroy
    end
  end

  it "still defaults a full-screen window's replacement to alternate mode" do
    w = b15m_window(30, 5)
    w2 = w.switch_terminal "xterm"
    begin
      w2.alternate?.should be_true
      w2.auto_grow?.should be_false
      w2.max_height.should be_nil
    ensure
      w2.destroy
    end
  end
end
