require "./spec_helper"

include Crysterm

# Regression specs for BUGS18 render/windowing findings B18-01, B18-05,
# B18-07, B18-10 (src/screen_input.cr, src/window.cr, src/window_connection.cr):
#
# B18-01 — the input fiber's teardown `rescue IO::Error` must wrap the
#          blocking `tput.listen` call itself, not the listen block body:
#          closing an owned input fd under a parked reader raises *between*
#          block invocations, and a block-body rescue never sees it — the
#          fiber died with an "Unhandled exception in spawn" backtrace on the
#          launching terminal instead of the documented silent teardown.
# B18-05 — `Window#title=` must store the title always but write the OSC 0
#          escape only while connected AND device-active: a background
#          sibling's write retitled the terminal showing the active window,
#          and a disconnected window's write raised on its closed fds. The
#          stored title is re-asserted (with the cursor) whenever the window
#          (re)takes a terminal: `activate`, `connect`, and `screen=`.
# B18-07 — `Window#close` must mirror `#on_window_closed` (disconnect, emit,
#          and only then destroy — and NOT when the handler reattached), so
#          the documented `Application.open(into: self)` reattach pattern
#          survives the programmatic close path too.
# B18-10 — `#switch_terminal` must carry runtime-settable options the
#          constructor can't take (hyperlinks, synchronized_output,
#          send_focus, frame_interval, drag knobs, overflow, default cell
#          attr/char, mouse_cursor_shaping) onto the replacement instead of
#          silently reverting them to config defaults.

private def b18rw_window(w = 40, h = 10)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

private def b18rw_shared_screen(w = 40, h = 10)
  Crysterm::Screen.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h)
end

# `dup` is not in Crystal's lib_c bindings (only `dup2`); needed to save and
# restore the process's stderr fd around the B18-01 capture.
lib LibC
  fun dup(x0 : Int) : Int
end

describe "BUGS18 B18-01: input fiber ends silently when its fd closes mid-read" do
  it "does not leak an unhandled IO::Error out of the input fiber" do
    reader, writer = IO.pipe
    dev = Crysterm::Screen.new(
      input: reader, output: IO::Memory.new, error: IO::Memory.new,
      width: 20, height: 5)
    dev.start_input
    # Let the fiber park in `read_char` on the (empty) pipe.
    sleep 50.milliseconds

    # Capture the process's real stderr: Crystal prints unhandled fiber
    # exceptions there ("Unhandled exception in spawn"), which is the only
    # observable difference between a rescued and an escaped IO::Error.
    capture = File.tempfile "b18_01_stderr"
    saved_fd = LibC.dup(2)
    begin
      STDERR.reopen capture
      # Close the input fd under the parked reader — the shape of every
      # owned-IO teardown (`disconnect`, `connect`'s reattach, `screen=`'s
      # migration). The woken fiber's IO::Error must be swallowed by the
      # teardown rescue, not escape `tput.listen` and the spawn block.
      reader.close
      sleep 150.milliseconds
      STDERR.flush
    ensure
      LibC.dup2(saved_fd, 2)
      LibC.close(saved_fd)
    end

    captured = File.read capture.path
    capture.delete
    captured.should_not contain "Unhandled exception in spawn"

    dev.stop_input
    writer.close rescue nil
  end
end

describe "BUGS18 B18-05: title= writes only when connected and device-active" do
  it "stores but does not write a background sibling's title on a shared device" do
    s = b18rw_shared_screen
    a = Window.new(screen: s, default_quit_keys: false)
    b = Window.new(screen: s, default_quit_keys: false)
    app = Application.new
    app.add a
    app.add b # b is device-active
    out = s.output.as(IO::Memory)
    out.clear

    a.title = "BG-TITLE"
    # Pre-fix the OSC 0 write immediately retitled the terminal showing b.
    out.to_s.includes?("\e]0;BG-TITLE\a").should be_false
    a.title.should eq "BG-TITLE"

    # The stored title is pushed when the window actually takes the device.
    app.activate a
    out.to_s.includes?("\e]0;BG-TITLE\a").should be_true

    a.destroy
    b.destroy
  end

  it "writes the device-active window's title immediately" do
    s = b18rw_shared_screen
    a = Window.new(screen: s, default_quit_keys: false)
    b = Window.new(screen: s, default_quit_keys: false)
    app = Application.new
    app.add a
    app.add b # b is device-active
    out = s.output.as(IO::Memory)
    out.clear

    b.title = "FG-TITLE"
    out.to_s.includes?("\e]0;FG-TITLE\a").should be_true

    a.destroy
    b.destroy
  end

  it "does not write on a disconnected window and re-asserts on reconnect" do
    w = b18rw_window
    w.disconnect
    out = w.output.as(IO::Memory)
    out.clear

    # Pre-fix this wrote the OSC 0 escape to the dead connection's IO (an
    # IO::Error on real closed fds); it must only store.
    w.title = "SAVED"
    out.to_s.should eq ""

    new_out = IO::Memory.new
    w.connect(IO::Memory.new, new_out)
    begin
      # `connect` re-asserts the stored title on the new terminal.
      new_out.to_s.includes?("\e]0;SAVED\a").should be_true
    ensure
      w.destroy
    end
  end

  it "screen= migration re-applies the stored title on the new device" do
    w = b18rw_window
    w.title = "CARRY"
    dev2 = b18rw_shared_screen
    w.screen = dev2
    begin
      # Pre-fix a direct migration lost the title until the next `activate`.
      dev2.output.as(IO::Memory).to_s.includes?("\e]0;CARRY\a").should be_true
    ensure
      w.destroy
    end
  end
end

describe "BUGS18 B18-07: close honors a handler's reattach" do
  it "destroys the window when no handler reattaches" do
    w = b18rw_window
    w.close.should be_true
    w.destroyed?.should be_true
    w.connected?.should be_false
    # Idempotent: a second close reports the window was not open.
    w.close.should be_false
  end

  it "leaves a handler-reattached window alive and connected" do
    w = b18rw_window
    new_input = IO::Memory.new
    new_out = IO::Memory.new
    saw_disconnected = false
    w.on(Event::WindowClosed) do
      # Both close paths must look identical to a handler: the surface is
      # already disconnected when the signal arrives (as on the emulator-close
      # watcher path).
      saw_disconnected = !w.connected?
      w.connect(new_input, new_out)
    end

    w.close.should be_true
    begin
      saw_disconnected.should be_true
      # Pre-fix `close`'s unconditional destroy tore down the connection the
      # handler just established: fresh fds closed, loops killed, @destroyed.
      w.destroyed?.should be_false
      w.connected?.should be_true
      new_input.closed?.should be_false
      new_out.closed?.should be_false
    ensure
      w.destroy
    end
  end
end

describe "BUGS18 B18-10: switch_terminal carries runtime-set options" do
  it "copies runtime-settable options onto the replacement" do
    # Force headless so the replacement binds in-memory IO even when specs
    # run on a real terminal.
    Crysterm::Config.set "screen.headless", Crysterm::Headless::Always
    begin
      w = b18rw_window
      w.hyperlinks = false
      w.synchronized_output = false
      w.send_focus = true
      w.frame_interval = 250.milliseconds
      w.drag_two_click = true
      w.drag_ghost = false
      w.overflow = Crysterm::Overflow::SkipWidget
      w.default_attr = 12345_i64
      w.default_char = '#'
      w.mouse_cursor_shaping = true

      w2 = w.switch_terminal "xterm"
      begin
        # Pre-fix each of these silently reverted to its config default.
        w2.hyperlinks?.should be_false
        w2.synchronized_output?.should be_false
        w2.send_focus?.should be_true
        w2.frame_interval.should eq 250.milliseconds
        w2.drag_two_click?.should be_true
        w2.drag_ghost?.should be_false
        w2.overflow.should eq Crysterm::Overflow::SkipWidget
        w2.default_attr.should eq 12345_i64
        w2.default_char.should eq '#'
        w2.mouse_cursor_shaping?.should be_true
      ensure
        w2.destroy
      end
    ensure
      Crysterm::Config.set "screen.headless", Crysterm::Headless::Auto
    end
  end
end
