require "./spec_helper"

include Crysterm

# `Animation`'s loop runs in a spawned fiber that `#stop` cancels only
# cooperatively (it sets `@running = false`; the fiber notices on its next
# wake). A `#stop` immediately followed by a `#start` on the *same* instance
# re-sets `@running = true` before the old fiber observes the stop — without a
# guard that would leave the old fiber ticking alongside the new one (and both
# would finalize / fire `on_stop`). The generation token prevents that.

describe Crysterm::Animation do
  it "does not leave a superseded fiber running after a same-instance stop+start" do
    stops = 0
    anim = Crysterm::Animation.new(1.millisecond) { }
    anim.on_stop { stops += 1 }

    anim.start
    anim.stop
    anim.start # supersedes the first run before its fiber observes the stop

    sleep 40.milliseconds   # let the superseded fiber wake and exit, new run tick
    anim.running?.should be_true # the new run is the sole active one

    anim.stop
    sleep 40.milliseconds
    anim.running?.should be_false
    # Exactly one `on_stop`: only the final genuine stop fires it. Without the
    # generation guard the orphaned (superseded) fiber also finalizes → 2.
    stops.should eq 1
  end
end
