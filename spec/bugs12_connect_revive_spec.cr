require "./spec_helper"

include Crysterm

# Regression specs for BUGS12 finding #5 (src/window_connection.cr):
#
# `Window#destroy` permanently stops the render/resize loop fibers (their stop
# flags are set and their doorbells rung), drops the window from
# `Window.instances` and from its `Application`'s routing table, and leaves a
# dangling (unsubscribed) global-resize handler. `Window#connect` deliberately
# supports rebinding a destroyed window, but used to only clear `@destroyed` —
# yielding a window that claimed to be alive while every `render` rang
# `@render_wakeup` with no receiver (permanently blank terminal) and resizes
# were never processed. `#connect` now calls `#revive`, which resets the stop
# flags before respawning both loops (generation-tagged, so a not-yet-exited
# old fiber can't race its replacement) and re-registers the window.

private def revive_window
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# Spins the event loop until *block* is truthy or the deadline passes (raising
# so a never-satisfied condition fails loudly rather than hanging forever).
private def wait_until(timeout = 2.seconds, &)
  deadline = Time.instant + timeout
  until yield
    raise "wait_until: condition not met within #{timeout}" if Time.instant > deadline
    sleep 2.milliseconds
  end
end

describe "BUGS12 #5 connect() revives a destroyed Window" do
  it "respawns the render loop: a render after destroy + connect completes" do
    w = revive_window
    rendered = 0
    w.on(Crysterm::Event::Rendered) { rendered += 1 }

    w.destroy
    w.destroyed?.should be_true
    # Let the old loop fibers observe their stop flags and exit, so this test
    # covers the plain (non-racing) revival path; the racing path is below.
    sleep 20.milliseconds

    out2 = IO::Memory.new
    w.connect(IO::Memory.new, out2)
    w.destroyed?.should be_false
    w.connected?.should be_true

    # `#connect` requests a repaint itself; without a live render fiber the
    # doorbell rings with no receiver and this never fires.
    wait_until { rendered >= 1 }
    out2.to_s.should_not be_empty

    w.destroy
  end

  it "respawns the render loop even when connect races destroy (no yield between)" do
    w = revive_window
    rendered = 0
    w.on(Crysterm::Event::Rendered) { rendered += 1 }

    # No yield between destroy and connect: the old loop fibers have been
    # woken but haven't run yet when the stop flags are reset. The generation
    # bump must retire them; the fresh loops must still serve renders.
    w.destroy
    w.connect(IO::Memory.new, IO::Memory.new)

    wait_until { rendered >= 1 }

    # And the doorbell keeps working for subsequent explicit renders.
    base = rendered
    w.render
    wait_until { rendered > base }

    w.destroy
  end

  it "respawns the resize loop: a resize after destroy + connect is processed" do
    w = revive_window
    w.resize_interval = 10.milliseconds

    w.destroy
    sleep 20.milliseconds
    w.connect(IO::Memory.new, IO::Memory.new)

    resizes = 0
    w.on(Crysterm::Event::Resize) { resizes += 1 }

    # Same path as SIGWINCH. Also covers the global-resize resubscription:
    # destroy unsubscribed the handler (and must drop the dangling wrapper,
    # or connect's `||=` would skip resubscribing).
    GlobalEvents.emit Crysterm::Event::Resize
    wait_until { resizes >= 1 }

    w.destroy
  end

  it "re-registers the revived window in Window.instances (at_exit restore registry)" do
    w = revive_window
    Window.instances.includes?(w).should be_true

    w.destroy
    Window.instances.includes?(w).should be_false

    w.connect(IO::Memory.new, IO::Memory.new)
    Window.instances.includes?(w).should be_true

    w.destroy
    Window.instances.includes?(w).should be_false
  end

  it "re-registers with its Application and receives routed input again" do
    reader, writer = IO.pipe
    reader2, writer2 = IO.pipe
    begin
      screen = Crysterm::Screen.new(
        input: reader, output: IO::Memory.new, error: IO::Memory.new,
        width: 40, height: 10)
      w = Crysterm::Window.new(screen: screen, default_quit_keys: false)
      app = Crysterm::Application.new
      app.add w

      seen = [] of Char
      w.on(Crysterm::Event::KeyPress) { |e| seen << e.char }

      screen.start_input
      writer.write "a".to_slice
      writer.flush
      wait_until { seen.size >= 1 }

      # Destroy removes the window from the app's routing table...
      w.destroy
      app.windows.includes?(w).should be_false
      sleep 20.milliseconds

      # ...and a revival must re-add it (and restore listening, which was
      # active at destroy time), so keys on the new terminal reach it again.
      w.connect(reader2, IO::Memory.new)
      app.windows.includes?(w).should be_true

      writer2.write "b".to_slice
      writer2.flush
      wait_until { seen.size >= 2 }
      seen.should eq ['a', 'b']

      w.destroy
    ensure
      writer.close rescue nil
      reader.close rescue nil
      writer2.close rescue nil
      reader2.close rescue nil
    end
  end

  it "destroy still works on a revived window (revival is symmetric)" do
    w = revive_window
    w.destroy
    sleep 20.milliseconds
    w.connect(IO::Memory.new, IO::Memory.new)

    resizes = 0
    w.on(Crysterm::Event::Resize) { resizes += 1 }
    w.resize_interval = 30.milliseconds

    # Second destroy: the respawned fibers must stop again (mirrors the
    # BUGS-F1 #12 guarantee, but for revived loops).
    w.destroy
    w.destroyed?.should be_true

    GlobalEvents.emit Crysterm::Event::Resize
    sleep 100.milliseconds
    resizes.should eq 0
  end
end
