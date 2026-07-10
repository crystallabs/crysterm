require "./spec_helper"

# Regression spec for two BUGS13 findings in the reactive core:
#
#   R4 — `Signal#value=` / `Computed`'s internal effect emitted `Changed` with
#        the *emitting* effect still on the tracking-scope stack, so listeners'
#        signal reads registered as spurious dependencies of the emitter —
#        unrelated writes then re-ran upstream effects/computeds. Emits must
#        run untracked (listeners/bindings execute with no active scope).
#   R6 — `Effect#run` cleared last run's subscriptions *before* executing the
#        body; a raising body permanently detached the effect from every
#        dependency it didn't get to re-read (while `disposed?` stayed false).
#        The re-track must be transactional: keep the old deps on a raise.

include Crysterm

describe "BUGS13 R4 — Changed emits run outside the emitter's tracking scope" do
  it "does not make a listener's signal read a dependency of the writing effect" do
    a = Crysterm::Reactive::Signal.new 0
    b = Crysterm::Reactive::Signal.new 0
    s = Crysterm::Reactive::Signal.new 0

    runs = 0
    Crysterm::Reactive::Effect.new do
      runs += 1
      s.value = a.value + 1 # write inside the effect: emits Changed mid-run
    end
    runs.should eq 1

    # A plain listener that reads another signal. Under the bug, this read
    # happened with the effect on the scope stack, silently subscribing the
    # effect to `b`.
    s.on(Crysterm::Event::Changed) { b.value }

    a.value = 10 # re-run the effect; s changes; the listener reads b
    runs.should eq 2

    b.value = 99 # unrelated write — must NOT re-run the effect
    runs.should eq 2
  end

  it "does not make a Changed listener's read a dependency of a Computed" do
    n = Crysterm::Reactive::Signal.new 1
    other = Crysterm::Reactive::Signal.new 0

    computes = 0
    c = Crysterm::Reactive::Computed(Int32).new do
      computes += 1
      n.value * 2
    end
    computes.should eq 2 # untracked prime + the internal effect's first run

    # Listener reading an unrelated signal during the computed's Changed emit.
    c.on(Crysterm::Event::Changed) { other.value }

    n.value = 2 # recompute + emit; listener reads `other`
    computes.should eq 3
    c.value.should eq 4

    other.value = 42 # unrelated write — must NOT recompute
    computes.should eq 3
  end
end

describe "BUGS13 R6 — a raising effect body keeps its previous dependencies" do
  it "stays subscribed to deps it did not re-read before the raise" do
    a = Crysterm::Reactive::Signal.new 0
    fail_flag = Crysterm::Reactive::Signal.new false

    runs = 0
    values = [] of Int32
    eff = Crysterm::Reactive::Effect.new do
      runs += 1
      raise "boom" if fail_flag.value
      values << a.value # not reached on a failing run
    end
    runs.should eq 1
    values.should eq [0]

    # Failing run: raises after reading fail_flag, *before* re-reading `a`.
    expect_raises(Exception, "boom") { fail_flag.value = true }
    runs.should eq 2
    eff.disposed?.should be_false

    # Under the bug `a`'s subscription was cleared up front and never rebuilt,
    # so this write was a silent no-op. With the transactional re-track the
    # old deps survive: the effect re-runs (and raises again, proving it ran).
    expect_raises(Exception, "boom") { a.value = 7 }
    runs.should eq 3

    # Recovery: clearing the flag re-runs cleanly and re-reads everything.
    fail_flag.value = false
    runs.should eq 4
    values.should eq [0, 7]
    a.value = 9
    runs.should eq 5
    values.should eq [0, 7, 9]
  end

  it "does not permanently freeze a Computed whose block raised once" do
    flag = Crysterm::Reactive::Signal.new false
    x = Crysterm::Reactive::Signal.new 1

    c = Crysterm::Reactive::Computed(Int32).new do
      raise "boom" if flag.value
      x.value * 10
    end
    c.value.should eq 10

    expect_raises(Exception, "boom") { flag.value = true }

    # `x` must still be a dependency (the failing run raised before reading
    # it); under the bug this write was silently ignored and `c` froze at 10.
    expect_raises(Exception, "boom") { x.value = 5 }

    flag.value = false # recompute cleanly
    c.value.should eq 50
  end

  it "keeps deps under a batch, where the exception is deferred to the flush" do
    a = Crysterm::Reactive::Signal.new 0
    fail_flag = Crysterm::Reactive::Signal.new false

    runs = 0
    Crysterm::Reactive::Effect.new do
      runs += 1
      raise "boom" if fail_flag.value
      a.value
    end
    runs.should eq 1

    expect_raises(Exception, "boom") do
      Crysterm::Reactive.batch { fail_flag.value = true }
    end
    runs.should eq 2

    # Dep on `a` must have survived the deferred failing run too.
    expect_raises(Exception, "boom") { a.value = 3 }
    runs.should eq 3
  end
end
