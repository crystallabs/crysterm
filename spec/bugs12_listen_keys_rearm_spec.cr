require "./spec_helper"

include Crysterm

# Regression spec for BUGS12 #6 (src/screen_input.cr): a stop_input ->
# start_input cycle must not "un-cancel" the previous input fiber still blocked
# in `tput.listen` (unowned STDIN survives `Window#disconnect`, so that fiber
# only wakes on its next event). With the old shared `@_keys_stopped` boolean,
# re-arming reset the flag to false, so the zombie fiber resumed dispatching
# alongside the new one — two interleaved readers on one fd. The per-spawn
# generation keeps the zombie cancelled: it drops its final consumed event (the
# check runs BEFORE dispatch) and exits, so every event dispatches exactly once.
#
# Which fiber consumes a given byte after the re-arm is scheduler-dependent and
# a zombie dispatch is per-event indistinguishable from a new-fiber dispatch, so
# the behavioral specs assert the invariants that hold under every interleaving
# (exactly-once, in order, at most one event dropped by the exiting zombie) and
# a structural spec pins the generation mechanism itself.

# Spins the event loop until *block* is truthy or the deadline passes (raising
# so a never-satisfied condition fails loudly rather than hanging forever).
private def wait_until(timeout = 2.seconds, &)
  deadline = Time.instant + timeout
  until yield
    raise "wait_until: condition not met within #{timeout}" if Time.instant > deadline
    sleep 2.milliseconds
  end
end

# Like `wait_until` but non-raising: returns whether the condition was met
# within *timeout*. For outcomes that are legitimately racy (the zombie may or
# may not consume — and drop — the event).
private def became?(timeout = 200.milliseconds, &) : Bool
  deadline = Time.instant + timeout
  until yield
    return false if Time.instant > deadline
    sleep 2.milliseconds
  end
  true
end

# Drives the *real* device input fiber (`Screen#start_input` -> `tput.listen`)
# over an in-process pipe (same harness as bugsf1_lifecycle_spec.cr).
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

describe "BUGS12 #6 start_input must not re-arm a stopped input fiber" do
  it "dispatches exactly once across a stop_input -> start_input cycle" do
    with_live_input do |_reader, writer, win, seen, screen|
      win.on(Crysterm::Event::KeyPress) { |e| seen << e.char }

      screen.start_input

      writer.write "a".to_slice
      writer.flush
      wait_until { seen.size >= 1 }
      seen.should eq ['a']

      # Detach and immediately re-arm, as a disconnect-then-listen does, while
      # the first fiber is still blocked in `tput.listen` (the pipe stays open,
      # mirroring unowned STDIN). With a shared stop flag this un-cancelled the
      # zombie and left two concurrent readers.
      screen.stop_input
      screen.start_input
      screen.listening?.should be_true

      # Feed events one at a time. The zombie consumes AT MOST one of them
      # (dropping it and exiting — never dispatching it); the new fiber
      # dispatches every event it consumes, exactly once, in order.
      fed = [] of Char
      "bcde".chars.each do |c|
        writer.write c.to_s.to_slice
        writer.flush
        fed << c
        became? { (seen.size - 1) >= fed.size } # tolerate the one zombie drop
      end

      # Ample time for a wrongly-live zombie to dispatch a swallowed event.
      sleep 60.milliseconds

      dispatched = seen[1..]
      # No duplicates anywhere (exactly-once).
      seen.should eq seen.uniq
      # At most one fed event went to the (exiting) zombie and was dropped.
      (fed.size - dispatched.size).should be <= 1
      # Everything dispatched came from the fed sequence, in order.
      dispatched.should eq(fed.select { |c| dispatched.includes? c })

      # The zombie exits on its first post-stop wake-up, so after the burst a
      # single reader remains: further events dispatch exactly once, promptly.
      pre = seen.size
      writer.write "z".to_slice
      writer.flush
      wait_until { seen.size >= pre + 1 }
      sleep 60.milliseconds
      seen.size.should eq pre + 1
      seen.last.should eq 'z'
    end
  end

  it "stays stopped when the zombie wakes before any re-arm, and two stops are safe" do
    with_live_input do |_reader, writer, win, seen, screen|
      win.on(Crysterm::Event::KeyPress) { |e| seen << e.char }

      screen.start_input
      screen.stop_input
      screen.stop_input # double stop: idempotent, no error
      screen.listening?.should be_false

      # Only the stopped fiber exists; it must consume 'x', drop it, and exit.
      writer.write "x".to_slice
      writer.flush
      sleep 60.milliseconds
      seen.should be_empty

      # A fresh listen after the zombie is gone starts a clean single reader.
      screen.start_input
      screen.listening?.should be_true

      writer.write "k".to_slice
      writer.flush
      wait_until { seen.size >= 1 }
      writer.write "m".to_slice
      writer.flush
      wait_until { seen.size >= 2 }

      sleep 60.milliseconds
      seen.should eq ['k', 'm']
    end
  end

  it "start_input is a no-op while a live fiber exists (no second reader)" do
    with_live_input do |_reader, writer, win, seen, screen|
      win.on(Crysterm::Event::KeyPress) { |e| seen << e.char }

      screen.start_input
      screen.start_input # must not spawn a second reader or cancel the first

      writer.write "ab".to_slice
      writer.flush
      wait_until { seen.size >= 2 }
      sleep 60.milliseconds
      seen.should eq ['a', 'b']
    end
  end

  it "wires the per-spawn cancel generation (structural)" do
    # A stale fiber's dispatch is observably identical to the live fiber's, so
    # the mechanism itself is pinned: cancellation must be a per-spawn
    # generation captured at spawn time — not a shared boolean a re-arm can
    # reset — checked before dispatch, and bumped by stop_input.
    src = File.read(File.join(__DIR__, "..", "src", "screen_input.cr"))
    src.should_not contain("@_keys_stopped")

    listen_start = src.index!("def start_input")
    listen_body = src[listen_start, 1200]
    listen_body.should contain("gen = (@_keys_gen += 1)")
    # The generation check precedes dispatch (route_input), so a zombie drops
    # its last consumed event instead of double-dispatching it.
    listen_body.index!("break if @_keys_gen != gen").should be <
                                                            listen_body.index!("route_input")

    stop_start = src.index!("def stop_input")
    stop_body = src[stop_start, 200]
    stop_body.should contain("@_keys_gen += 1")
    stop_body.should contain("@_keys_fiber = nil")
  end
end
