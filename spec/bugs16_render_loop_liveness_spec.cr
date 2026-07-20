require "./spec_helper"

include Crysterm

# B16-01: `render_loop` re-checks liveness (`@render_stop`, generation,
# `@connected`) AFTER the FPS-throttle sleep, before `_render`. In an animating
# UI the render fiber spends most of each frame period parked in that sleep, so
# a `#destroy`/`#disconnect` on another fiber very often lands inside it — the
# device is then restored (or handed back to a sibling) and the woken fiber must
# NOT paint a stray frame onto a terminal this window no longer owns.
#
# Headless (fixed-size `IO::Memory` device). A large `frame_interval` widens the
# throttle sleep so `#destroy` deterministically lands inside it: the window is
# rendered once (arming `@last_render_at`), a second render parks the fiber in
# the throttle, and `#destroy` runs while it sleeps.

private def shared_device
  Crysterm::Screen.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 40, height: 10)
end

private def win_on(dev : Crysterm::Screen)
  Crysterm::Window.new(screen: dev, default_quit_keys: false)
end

private def io_window
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 40, height: 10, default_quit_keys: false)
end

describe "BUGS16 B16-01: render_loop liveness after the throttle sleep" do
  it "paints no frame over a surviving sibling when destroy lands during the throttle sleep" do
    app = Crysterm::Application.new
    dev = shared_device
    w1 = win_on dev
    w2 = win_on dev
    app.add w1
    app.add w2

    # Wide throttle window so destroy reliably lands inside the sleep.
    w2.frame_interval = 0.5.seconds

    # First render: `@last_render_at` is nil, so it paints immediately and arms
    # the throttle.
    w2.render
    sleep 0.05.seconds
    w2.renders.should eq 1

    # Second render: the fiber wakes, passes the pre-sleep checks and parks in
    # the trailing throttle (elapsed < frame_interval).
    w2.render
    sleep 0.05.seconds

    # Teardown lands mid-sleep: sibling path, so the shared device stays live
    # (output not closed) for w1.
    w2.destroy
    dev_out = dev.output.as(IO::Memory)
    bytes_after_teardown = dev_out.size

    # Wait past the throttle so the render fiber wakes from the sleep.
    sleep 0.7.seconds

    # No stray frame: neither a render nor any bytes after teardown.
    w2.renders.should eq 1
    dev_out.size.should eq bytes_after_teardown
  end

  it "dumps no frame into the restored output when a single window is destroyed mid-throttle" do
    w = io_window
    w.frame_interval = 0.5.seconds

    w.render
    sleep 0.05.seconds
    w.renders.should eq 1

    w.render
    sleep 0.05.seconds

    w.destroy
    dev_out = w.screen.output.as(IO::Memory)
    bytes_after_teardown = dev_out.size

    sleep 0.7.seconds

    w.renders.should eq 1
    dev_out.size.should eq bytes_after_teardown
  end
end
