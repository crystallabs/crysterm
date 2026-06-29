require "./spec_helper"

include Crysterm

# Headless coverage of the connect/disconnect/reattach lifecycle
# (`window_connection.cr`). This path was previously exercised only indirectly
# (`startup_interrupt_restore_spec.cr` drives teardown). It is locked in here as
# the safety net for relocating the input fiber + listening state onto the
# device — see QT-OBJECT-MODEL-PLAN.md, input-routing split.
#
# Everything runs over `IO::Memory` pairs (no real tty): such a window does not
# own its IO (`@owns_io` stays false), so `#disconnect` never closes the buffers
# and we can keep inspecting them.

private def conn_window(output : IO) : Crysterm::Window
  Crysterm::Window.new(
    input: IO::Memory.new, output: output, error: IO::Memory.new,
    width: 80, height: 24)
end

describe "Window connect/disconnect lifecycle" do
  it "starts connected from the constructor" do
    conn_window(IO::Memory.new).connected?.should be_true
  end

  it "disconnect tears down the terminal and flips #connected?" do
    buf = IO::Memory.new
    w = conn_window buf
    mark = buf.to_s.size

    w.disconnect
    w.connected?.should be_false
    # restore_terminal ran: the alternate buffer was left.
    buf.to_s[mark..].should contain("\e[?1049l")
  end

  it "disconnect is idempotent (second call writes nothing, never raises)" do
    buf = IO::Memory.new
    w = conn_window buf
    w.disconnect
    after_first = buf.to_s.size
    w.disconnect
    buf.to_s.size.should eq after_first
  end

  it "reconnect swaps in a fresh device (QWindow#screen=) and repaints it" do
    w = conn_window IO::Memory.new
    old_device = w.screen
    w.disconnect

    new_out = IO::Memory.new
    w.connect(IO::Memory.new, new_out)

    w.connected?.should be_true
    # Reattach builds a *new* `Screen` and swaps it in (not an in-place rebuild).
    w.screen.should_not be(old_device)
    # Re-entered the alternate buffer on the *new* terminal.
    new_out.to_s.should contain("\e[?1049h")
    # The device's output is now the new buffer (delegated through @screen).
    w.output.should be(new_out)
  end

  it "restores prior listening state across a reattach" do
    w = conn_window IO::Memory.new
    w.listen # marks the window as listening; enabling mouse reporting is a side effect

    w.disconnect
    # The teardown turned mouse reporting back off.
    w._listened_mouse?.should be_false

    new_out = IO::Memory.new
    w.connect(IO::Memory.new, new_out)

    # Listening was active before, so the reattach re-establishes it (which
    # re-enables mouse reporting).
    w._listened_mouse?.should be_true
  end

  it "does not restore listening when it was never started" do
    w = conn_window IO::Memory.new
    # No #listen call.
    w.disconnect
    w.connect(IO::Memory.new, IO::Memory.new)
    w._listened_mouse?.should be_false
  end
end
