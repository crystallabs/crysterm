require "./spec_helper"

include Crysterm

# Regression specs for BUGS15 #68 and #74 (reactive subsystem).
#
# #68: `Reactive.flush` must be re-entrancy-safe. A deferred effect that
# writes a signal during the flush opens a nested propagation wave whose
# close calls `flush` again; effects still awaiting their turn in the outer
# drain must NOT be re-enqueued and run twice. The drain works on the live
# queue and removes an item from the dedup set only as it is taken, so a
# still-pending item stays deduplicated and runs exactly once.
#
# #74: `Effect#track` must no-op once the effect is disposed. A dispose that
# fires mid-run (e.g. the body tears down its owner) must not let signal
# reads after the dispose point re-subscribe `Event::Changed` handlers that
# can never be removed.
describe "BUGS15 reactive regressions" do
  describe "#68 flush re-entrancy (run-once guarantee)" do
    it "runs a later-queued effect once when an earlier effect writes a signal (plain write)" do
      a = Crysterm::Reactive::Signal.new 0
      s = Crysterm::Reactive::Signal.new 0

      e2_runs = 0
      e2_seen = {0, 0}
      # E1 reads `a` and writes `s`; E2 reads both, so one `a` write wakes
      # both, and E1's flush-time `s` write must not make E2 run twice.
      Crysterm::Reactive::Effect.new { s.value = a.value + 100 }
      Crysterm::Reactive::Effect.new do
        e2_seen = {a.value, s.value}
        e2_runs += 1
      end
      e2_runs = 0

      a.value = 1

      e2_runs.should eq 1
      e2_seen.should eq({1, 101})
    end

    it "runs a later-queued effect once when an earlier effect writes a signal (batched write)" do
      a = Crysterm::Reactive::Signal.new 0
      s = Crysterm::Reactive::Signal.new 0

      e2_runs = 0
      Crysterm::Reactive::Effect.new { s.value = a.value + 100 }
      Crysterm::Reactive::Effect.new do
        a.value
        s.value
        e2_runs += 1
      end
      e2_runs = 0

      Crysterm::Reactive.batch { a.value = 1 }

      e2_runs.should eq 1
    end

    it "runs the leaf of a 3-deep chain exactly once per write" do
      a = Crysterm::Reactive::Signal.new 0
      b = Crysterm::Reactive::Signal.new 0
      c = Crysterm::Reactive::Signal.new 0

      # Chain a→b→c built from leaf effects that write during the flush. Both
      # writers are woken by the original `a` write (the c-writer reads `a`
      # too), so all three sit in the queue ahead of the leaf; the leaf must
      # stay deduplicated through the writers' nested waves and run once, on
      # fully settled values.
      Crysterm::Reactive::Effect.new { b.value = a.value + 1 }
      Crysterm::Reactive::Effect.new { c.value = a.value + b.value }

      leaf_runs = 0
      leaf_seen = {0, 0, 0}
      Crysterm::Reactive::Effect.new do
        leaf_seen = {a.value, b.value, c.value}
        leaf_runs += 1
      end
      leaf_runs = 0

      a.value = 5

      leaf_runs.should eq 1
      leaf_seen.should eq({5, 6, 11})

      leaf_runs = 0
      Crysterm::Reactive.batch { a.value = 10 }

      leaf_runs.should eq 1
      leaf_seen.should eq({10, 11, 21})
    end
  end

  describe "#74 mid-run dispose" do
    it "leaves zero Changed handlers on signals read after the dispose point" do
      s1 = Crysterm::Reactive::Signal.new 0
      s2 = Crysterm::Reactive::Signal.new 0

      do_dispose = false
      eff : Crysterm::Reactive::Effect? = nil
      eff = Crysterm::Reactive::Effect.new do
        s1.value
        eff.try &.dispose if do_dispose
        s2.value
      end

      s1.handlers(Crysterm::Event::Changed).size.should eq 1
      s2.handlers(Crysterm::Event::Changed).size.should eq 1

      do_dispose = true
      s1.value = 1

      eff.try(&.disposed?).should be_true
      s1.handlers(Crysterm::Event::Changed).size.should eq 0
      s2.handlers(Crysterm::Event::Changed).size.should eq 0
    end

    it "does not run again after a mid-run dispose" do
      s1 = Crysterm::Reactive::Signal.new 0
      s2 = Crysterm::Reactive::Signal.new 0

      runs = 0
      do_dispose = false
      eff : Crysterm::Reactive::Effect? = nil
      eff = Crysterm::Reactive::Effect.new do
        runs += 1
        s1.value
        eff.try &.dispose if do_dispose
        s2.value
      end
      runs.should eq 1

      do_dispose = true
      s1.value = 1
      runs.should eq 2

      # The dead effect must not be woken by either signal again.
      s1.value = 2
      s2.value = 2
      runs.should eq 2
    end
  end
end
