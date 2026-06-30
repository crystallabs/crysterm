require "./spec_helper"

include Crysterm

# `FrameClock`'s loop runs in a spawned fiber that `#stop` cancels only
# cooperatively (it sets `@running = false`; the fiber notices on its next
# wake). A `#stop` immediately followed by a `#start` on the *same* instance
# re-sets `@running = true` before the old fiber observes the stop — without a
# guard that would leave the old fiber ticking alongside the new one (and both
# would finalize / fire `on_stop`). The generation token prevents that.

describe Crysterm::FrameClock do
  it "does not leave a superseded fiber running after a same-instance stop+start" do
    stops = 0
    anim = Crysterm::FrameClock.new(1.millisecond) { }
    anim.on_stop { stops += 1 }

    anim.start
    anim.stop
    anim.start # supersedes the first run before its fiber observes the stop

    sleep 40.milliseconds        # let the superseded fiber wake and exit, new run tick
    anim.running?.should be_true # the new run is the sole active one

    anim.stop
    sleep 40.milliseconds
    anim.running?.should be_false
    # Exactly one `on_stop`: only the final genuine stop fires it. Without the
    # generation guard the orphaned (superseded) fiber also finalizes → 2.
    stops.should eq 1
  end

  it "does not double-fire on_stop when reduced motion is enabled between a stop and a restart" do
    # A tween started normally (reduced motion off) spawns a fiber. After a
    # `#stop` — but before that fiber observes it — the preference flips on and
    # `#start` is called again: the reduced-motion path completes synchronously.
    # The early-return path must still bump the generation, or the orphaned
    # fiber, whose captured generation would otherwise still match, wakes and
    # finalizes a second time → a duplicate `on_stop`.
    Crysterm::Config.set "render.reduced_motion", false
    stops = 0
    # A tween (has a duration) so the reduced-motion branch applies.
    anim = Crysterm::FrameClock.new(20.milliseconds, duration: 10.seconds) { }
    anim.on_stop { stops += 1 }

    anim.start # normal path: spawns the loop fiber (not yet run — no yield point)
    anim.stop  # cooperative cancel; the fiber hasn't observed it yet
    Crysterm::Config.set "render.reduced_motion", true
    anim.start # reduced-motion path: completes synchronously, fires on_stop once

    sleep 60.milliseconds # let the orphaned fiber wake and (correctly) exit silently
    stops.should eq 1
  ensure
    Crysterm::Config.set "render.reduced_motion", false
  end
end
