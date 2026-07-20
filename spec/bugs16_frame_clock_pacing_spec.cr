require "./spec_helper"

include Crysterm

# B16-02: `FrameClock`'s loop fiber, when a tick's work costs more than
# `@interval`, takes the behind-schedule branch (`delay <= 0`). That branch used
# to only resync the phase (`next_at = Time.instant`) and loop straight back into
# the next `@on_tick.call` with no `sleep`/`Fiber.yield`. Crystal fibers are
# cooperative, so an iteration that performs no blocking operation never returns
# the thread to the scheduler: a ticker whose block keeps costing >= interval
# monopolizes it, and the render/input fibers (and every other fiber) are starved
# for the whole overload. The fix yields on the behind-schedule branch, so an
# overloaded ticker degrades to best-effort cadence instead of freezing everything.

describe "BUGS16 B16-02: FrameClock yields when behind schedule" do
  it "lets a competing fiber run between ticks when the tick block outruns the interval" do
    # A competing fiber that advances one step each time the scheduler runs it —
    # stands in for the render/input fibers the tick block would otherwise starve.
    progress = 0
    spawn(name: "b16-02-monitor") do
      loop do
        progress += 1
        Fiber.yield
      end
    end

    ticks = 0
    # `progress` sampled on the first and the last tick. Between them the clock
    # is permanently behind schedule, so any advance in `progress` can only come
    # from the behind-schedule branch handing control back to the scheduler.
    seen_first = 0
    seen_last = 0

    # Interval 1 ms, but each tick busy-waits ~3 ms of wall time (no blocking
    # call), so from the first inter-tick gap on the loop is always behind
    # schedule. Self-stops after a fixed count so the test can't hang if the
    # behind-schedule branch never yields (pristine code).
    clock = Crysterm::FrameClock.new(1.millisecond) do |c|
      busy_until = Time.instant + 3.milliseconds
      while Time.instant < busy_until
      end
      ticks += 1
      seen_first = progress if ticks == 1
      if ticks >= 20
        seen_last = progress
        c.stop
      end
    end

    clock.start
    sleep 300.milliseconds

    ticks.should eq 20
    # With the yield, the competing fiber is scheduled during the 19 behind-schedule
    # gaps between the first and last tick, so `progress` climbs. Without it, the
    # clock fiber never suspends once it is behind: from the first tick through the
    # stop it monopolizes the thread and the competing fiber is frozen — `progress`
    # is bit-for-bit identical at the first and last tick (a hard freeze, not a
    # slowdown). This is deterministic regardless of any other fibers in the run.
    seen_last.should be > seen_first
  end
end
