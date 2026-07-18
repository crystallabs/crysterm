require "./spec_helper"

include Crysterm

# Regression specs for the BUGS-F1 lifecycle fixes owned by this agent:
#
#   1  (src/screen_input.cr)      — a raising user input handler must not kill
#                                    the one input fiber (blanket per-loop rescue).
#   8  (src/crysterm.cr)          — `at_exit` must destroy every window even
#                                    though `destroy` mutates `Window.instances`.
#   12 (src/window_resize.cr,     — `destroy` must stop the resize fiber instead
#       src/window.cr)              of leaking it (and never `#refresh_size` a
#                                    dead window).
#   13 (src/window_connection.cr, — a stale input fiber must stop dispatching to
#       src/screen_input.cr)        a detached screen after `stop_input`.

private def f1_window
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# Spins the event loop until *block* is truthy or the deadline passes (raising so
# a never-satisfied condition fails loudly rather than hanging forever).
private def wait_until(timeout = 2.seconds, &)
  deadline = Time.instant + timeout
  until yield
    raise "wait_until: condition not met within #{timeout}" if Time.instant > deadline
    sleep 2.milliseconds
  end
end

# Drives the *real* device input fiber (`Screen#start_input` -> `tput.listen`)
# over an in-process pipe, so the per-event/stop-flag behavior is exercised end
# to end instead of asserted structurally. Yields {reader, writer, window, seen}.
private def with_live_input(&)
  reader, writer = IO.pipe
  screen = Crysterm::Screen.new(
    input: reader, output: IO::Memory.new, error: IO::Memory.new,
    width: 40, height: 10)
  win = Crysterm::Window.new(screen: screen, default_quit_keys: false)
  app = Crysterm::Application.new
  app.add win

  seen = [] of Char
  begin
    yield reader, writer, win, seen, screen
  ensure
    writer.close rescue nil
    reader.close rescue nil
  end
end

describe "BUGS-F1 #1 input fiber survives a raising handler" do
  it "keeps dispatching after a user KeyPress handler raises" do
    with_live_input do |_reader, writer, win, seen, screen|
      win.on(Crysterm::Event::KeyPress) do |e|
        seen << e.char
        raise "boom in user handler" if e.char == 'a'
      end

      screen.start_input

      # First key's handler raises; second key must still be dispatched.
      writer.write "ab".to_slice
      writer.flush

      wait_until { seen.size >= 2 }
      seen.should eq ['a', 'b']
    end
  end
end

describe "BUGS-F1 #13 detached input fiber stops dispatching" do
  it "drops events routed after stop_input" do
    with_live_input do |_reader, writer, win, seen, screen|
      win.on(Crysterm::Event::KeyPress) { |e| seen << e.char }

      screen.start_input

      writer.write "a".to_slice
      writer.flush
      wait_until { seen.size >= 1 }
      seen.should eq ['a']

      # Detach the device (as Window#disconnect does for unowned STDIN): the
      # fiber must stop routing to this now-detached screen.
      screen.stop_input

      writer.write "b".to_slice
      writer.flush
      # Give the fiber ample time to (wrongly) dispatch 'b' if the flag were
      # not honored; it must not.
      sleep 60.milliseconds
      seen.should eq ['a']
    end
  end
end

describe "BUGS-F1 #8 at_exit destroys every window despite registry mutation" do
  it "dup-iterating the registry destroys all windows (delete-during-each safe)" do
    w1 = f1_window
    w2 = f1_window
    w3 = f1_window

    Window.instances.includes?(w1).should be_true
    Window.instances.includes?(w2).should be_true
    Window.instances.includes?(w3).should be_true

    # The exact teardown `at_exit` now performs.
    Window.instances.dup.each &.destroy

    w1.destroyed?.should be_true
    w2.destroyed?.should be_true
    w3.destroyed?.should be_true
  end

  it "demonstrates the root cause: deleting during index-based each skips elements" do
    arr = [1, 2, 3]
    visited = [] of Int32
    # Mirrors `Window.instances.each &.destroy` where destroy deletes self.
    arr.each { |x| visited << x; arr.delete x }
    # The naive in-place iteration skips elements (here, 2) — which is why the
    # fix iterates a `.dup` instead.
    visited.should_not eq [1, 2, 3]
  end
end

describe "BUGS-F1 #12 destroy stops the resize fiber" do
  it "does not run #refresh_size on a destroyed window for a resize pending at destroy" do
    w = f1_window
    # Large debounce so the resize fiber is parked in its drain wait when we
    # destroy, exercising the pending-notification path.
    w.resize_interval = 300.milliseconds

    resizes = 0
    w.on(Crysterm::Event::Resize) { resizes += 1 }

    # Trigger a resize through the global signal (same path as SIGWINCH); the
    # fiber wakes and enters its debounce wait.
    GlobalEvents.emit Crysterm::Event::Resize
    sleep 40.milliseconds

    w.destroy

    # With the fix the fiber breaks out on the @resize_stop flag; without it the
    # debounce elapses and #refresh_size runs on the dead window, emitting Resize.
    sleep 450.milliseconds
    resizes.should eq 0
  end

  it "wires the resize-fiber teardown (structural)" do
    resize_src = File.read(File.join(__DIR__, "..", "src", "window_resize.cr"))
    resize_src.should contain("@resize_stop")
    resize_src.should contain("break if @resize_stop")

    window_src = File.read(File.join(__DIR__, "..", "src", "window.cr"))
    destroy_start = window_src.index!("def destroy")
    destroy_body = window_src[destroy_start, 800]
    destroy_body.should contain("@resize_stop = true")
    destroy_body.should contain("schedule_resize")
  end
end
