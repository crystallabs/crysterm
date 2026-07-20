require "./spec_helper"

include Crysterm

# Regression specs for BUGS17 findings B17-02 / B17-03 — the render core:
#
# B17-02 — `render_loop` had no device-active gate: a background window on a
#          device shared by several `Window`s still composited/flushed its own
#          frames (rung by its timers/transitions/`post` jobs) over the active
#          sibling's display. Only the device-active window may paint the shared
#          terminal; a backgrounded window's deferred changes are repainted in
#          full when `Application#activate` raises it.
# B17-03 — `request_frame`'s in-render suppression was a window-wide flag with
#          no fiber identity, so a cross-fiber mutation landing at one of
#          `_render`'s yield points (the `flush_frame` tty write, a `PreRender`/
#          `Rendered` handler doing IO) was dropped and never repainted. The
#          suppression is now scoped to the render fiber, so only same-fiber
#          layout setters stay suppressed; cross-fiber updates ring the doorbell.

private def b17_device
  Crysterm::Screen.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 40, height: 10)
end

private def b17_window(dev)
  Crysterm::Window.new(screen: dev, default_quit_keys: false,
    resize_interval: 10.milliseconds)
end

# Spins the event loop until *block* is truthy or the deadline passes (raising
# so a never-satisfied condition fails loudly rather than hanging forever).
private def b17_wait_until(timeout = 2.seconds, &)
  deadline = Time.instant + timeout
  until yield
    raise "b17_wait_until: condition not met within #{timeout}" if Time.instant > deadline
    sleep 2.milliseconds
  end
end

describe "BUGS17 B17-02: background window does not paint the shared device" do
  it "writes nothing when a non-active sibling's render loop is rung" do
    dev = b17_device
    w1 = b17_window dev
    w2 = b17_window dev
    begin
      box = Widget::Box.new parent: w1, left: 0, top: 0, width: 20, height: 1,
        content: "W1ORIG"
      app = Application.new
      app.add w1
      app.add w2 # creation/add order: w1 first, w2 last

      out = dev.output.as(IO::Memory)
      # Raise w2 so it owns the shared display; let its repaint land, then
      # settle so no scheduled render bleeds into the assertions below.
      app.activate w2
      sleep 80.milliseconds
      out.clear

      # w1 is now the background window. A widget mutation on it funnels
      # mark_dirty -> request_frame -> schedule_render, ringing w1's render
      # loop. Pre-fix that loop composited and flushed w1's changed cells onto
      # the shared tty, over w2's frame. It must now write nothing at all.
      box.content = "W1CHANGED"
      w1.render # explicitly ring w1's doorbell too
      sleep 80.milliseconds
      out.to_s.should eq ""

      # Raising w1 repaints it in full, so the change deferred while it was
      # backgrounded now reaches the display.
      app.activate w1
      b17_wait_until { out.to_s.includes? "W1CHANGED" }
    ensure
      w1.destroy
      w2.destroy
    end
  end
end

describe "BUGS17 B17-03: cross-fiber request_frame during _render is not dropped" do
  it "schedules a follow-up frame for a mutation landing at a _render yield point" do
    dev = b17_device
    win = b17_window dev
    begin
      # Prime one frame so the loop is idle and parked on the doorbell.
      win.render
      b17_wait_until { win.renders > 0 }
      baseline = win.renders

      # A `PreRender` handler runs on the render fiber while `@in_render` is
      # set. From INSIDE it we run `request_frame` on a DIFFERENT fiber (the
      # cross-fiber mutation the real bug describes — a key handler / spawned
      # worker mutating a widget while the render fiber is parked mid-frame),
      # synchronizing so it completes before the frame ends. Pre-fix the
      # window-wide `@in_render` flag suppressed that call and no second frame
      # ran; the fiber-scoped guard now rings the doorbell.
      fired = false
      win.on(Crysterm::Event::PreRender) do
        unless fired
          fired = true
          done = Channel(Nil).new
          spawn do
            win.request_frame
            done.send nil
          end
          done.receive # let the cross-fiber request_frame run mid-frame
        end
      end

      win.render # ring the doorbell -> frame -> PreRender -> cross-fiber request_frame
      # Fix produces two frames (this one plus the scheduled follow-up); pre-fix
      # only one, because the cross-fiber request_frame was suppressed.
      b17_wait_until { win.renders >= baseline + 2 }
    ensure
      win.destroy
    end
  end
end
