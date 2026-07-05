require "./spec_helper"

include Crysterm

private def msg_window
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# A *timed* Message spawns a fiber that calls `end_it gen` after its sleep.
# Destroying the message before the timeout must invalidate that pending fiber
# (via the generation bump), so the stale timeout can't dismiss/callback against
# the torn-down widget — the timed counterpart of the keypress-dismiss cleanup.
describe Crysterm::Widget::Message do
  it "invalidates a pending timed-dismissal after destroy" do
    s = msg_window
    msg = Crysterm::Widget::Message.new parent: s, width: 20, height: 3

    ran = false
    # A long timeout so the real fiber never fires during the test; the fiber
    # captures generation 1 (the first `#display`).
    msg.display("hi", 5.seconds) { ran = true }

    msg.destroy

    # Simulate the still-armed timeout fiber waking after destroy and invoking
    # `end_it` with the generation it captured. After the fix this is a no-op.
    msg.end_it(1) { ran = true }
    ran.should be_false
  ensure
    s.try &.destroy
  end
end
