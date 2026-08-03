require "./spec_helper"

include Crysterm

# Regression specs for BUGS16 findings B16-03 / B16-04 / B16-06 — the
# shared-device window lifecycle:
#
# B16-03 — a non-active sibling's realloc (resize path) must not physically
#          clear the shared tty: it would wipe the active window's freshly
#          painted frame, whose `@flushed_lines` still claims the content is
#          on screen, so the next frame diff emits nothing and the terminal
#          stays blank.
# B16-04 — `#switch_terminal` must stop the old window's input fiber BEFORE
#          constructing (and probing) the replacement on the same tty, and
#          must carry the listening state across.
# B16-06 — an in-band resize report (DEC 2048) describes the device; the
#          dispatcher must broadcast it to every window sharing the screen,
#          and `#activate` must not composite a window whose buffers predate
#          a device resize.

private def b16sd_device
  Crysterm::Screen.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

private def b16sd_window(dev)
  Crysterm::Window.new(screen: dev, default_quit_keys: false,
    resize_interval: 10.milliseconds)
end

# Records, at each `stop_input`, how many `Window` instances existed — so a
# spec can pin that `#switch_terminal` stops the old device's input BEFORE the
# replacement window is constructed on the same tty (B16-04).
private class B16sdSpyScreen < Crysterm::Screen
  getter stop_input_window_counts = [] of Int32

  def stop_input : Nil
    @stop_input_window_counts << Crysterm::Window.instances.size
    super
  end
end

describe "BUGS16 B16-03: non-active sibling realloc leaves the shared tty alone" do
  it "emits no physical clear from a non-active window's resize realloc" do
    dev = b16sd_device
    a = b16sd_window dev
    b = b16sd_window dev
    begin
      Widget::Box.new parent: a, left: 0, top: 0, width: 10, height: 1, content: "AAA16"
      app = Application.new
      app.add a
      app.add b # creation order: a first, b last

      out = dev.output.as(IO::Memory)
      # Raise the FIRST-created window; wait for its repaint to land, then
      # settle so no scheduled render bleeds into the assertions below.
      app.activate a
      wait_until { out.to_s.includes? "AAA16" }
      sleep 80.milliseconds
      out.clear

      # The non-active sibling's `on_resize` reallocs synchronously; `alloc`
      # must not end with `tput.clear` on the SHARED tty, which would erase
      # the active window's frame behind its back. It must write nothing at all.
      size = ::Crysterm::Size.new(a.awidth - 4, a.aheight - 2)
      b.emit ::Crysterm::Event::Resize.new size
      sleep 80.milliseconds
      out.to_s.should eq ""

      # The device-active window still clears and repaints on its own resize.
      a.emit ::Crysterm::Event::Resize.new size
      wait_until { out.to_s.includes? "AAA16" }
    ensure
      a.destroy
      b.destroy
    end
  end
end

describe "BUGS16 B16-04: switch_terminal input-fiber handover" do
  it "stops the old device's input before constructing the replacement" do
    spy = B16sdSpyScreen.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 30, height: 8)
    w = Crysterm::Window.new(screen: spy, default_quit_keys: false)
    baseline = Crysterm::Window.instances.size
    w2 = w.switch_terminal "xterm"
    begin
      spy.stop_input_window_counts.empty?.should be_false
      # At the first `stop_input` the replacement must NOT exist yet: stopping
      # the old input fiber only inside `destroy` (via `reparent_onto`), AFTER
      # the replacement was built — and probed — would race the old fiber
      # against the same tty.
      spy.stop_input_window_counts.first.should eq baseline
    ensure
      w2.destroy
    end
  end

  it "carries the listening state to the replacement window" do
    # The replacement (and its restored input fiber) binds in-memory IO because
    # `spec_helper` pins `screen.headless` to `Always` — `switch_terminal` gives
    # the new window fresh *default* IO, so nothing here can pass it explicitly.
    w = Crysterm::Window.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 30, height: 8, default_quit_keys: false)
    w.start_input
    w.screen.listening?.should be_true

    w2 = w.switch_terminal "xterm"
    begin
      # Restoring input on the replacement guards against the old fiber
      # racing the constructor probe and the new window coming up deaf
      # until an explicit `start_input`.
      w2.screen.listening?.should be_true
    ensure
      w2.destroy
    end
  end

  it "leaves a non-listening window's replacement not listening" do
    w = Crysterm::Window.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 30, height: 8, default_quit_keys: false)
    w2 = w.switch_terminal "xterm"
    begin
      w2.screen.listening?.should be_false
    ensure
      w2.destroy
    end
  end
end

describe "BUGS16 B16-06: in-band resize reaches every window on the device" do
  it "reallocs non-active siblings' buffers via the dispatcher broadcast" do
    dev = b16sd_device
    w1 = b16sd_window dev
    w2 = b16sd_window dev
    begin
      app = Application.new
      app.add w1
      app.add w2 # w2 active

      rows = w1.aheight + 3
      cols = w1.awidth + 5
      e = Tput::InputEvent.new('\u0000',
        resize: Tput::Resize.new(rows: rows, cols: cols, pixel_height: 0, pixel_width: 0))
      app.route_input dev, e

      # Each window debounces the report on its own resize loop; the broadcast
      # must reach every window on the device, not just the active w2, or
      # w1's buffers would stay stale forever.
      wait_until { w2.lines.size == rows }
      wait_until { w1.lines.size == rows }
      w1.lines[0].size.should eq cols
    ensure
      w1.destroy
      w2.destroy
    end
  end

  it "activate reallocs a window whose buffers predate a device resize" do
    dev = b16sd_device
    w1 = b16sd_window dev
    w2 = b16sd_window dev
    begin
      app = Application.new
      app.add w1
      app.add w2 # w2 active

      # The device size changes while w1 is non-active and its debounced
      # refresh hasn't (yet) caught up — any path that resizes the device
      # behind a non-active window's back.
      new_w = w1.awidth - 4
      new_h = w1.aheight - 2
      dev.resize new_w, new_h
      w1.lines.size.should_not eq new_h # stale, by construction

      app.activate w1
      # `activate` reallocs before the full repaint, so the raised window is
      # not composited with buffers clipped to the old rows/columns.
      w1.lines.size.should eq new_h
      w1.lines[0].size.should eq new_w
    ensure
      w1.destroy
      w2.destroy
    end
  end
end
