require "./spec_helper"

include Crysterm

# A *timed* Message spawns a fiber that calls `end_it gen` after its sleep.
# Destroying the message before the timeout must invalidate that pending fiber
# (via the generation bump), so the stale timeout can't dismiss/callback against
# the torn-down widget — the timed counterpart of the keypress-dismiss cleanup.
describe Crysterm::Widget::MessageBox do
  it "invalidates a pending timed-dismissal after destroy" do
    s = headless_screen(80, 24)
    msg = Crysterm::Widget::MessageBox.new parent: s, width: 20, height: 3

    ran = false
    # A long timeout so the real fiber never fires during the test; the fiber
    # captures generation 1 (the first `#display`).
    msg.open("hi", 5.seconds) { ran = true }

    msg.destroy

    # Simulate the still-armed timeout fiber waking after destroy and invoking
    # `end_it` with the generation it captured. This must be a no-op.
    msg.end_it(1) { ran = true }
    ran.should be_false
  ensure
    s.try &.destroy
  end
end
