require "./spec_helper"

include Crysterm

# Glitch-free propagation regressions (BUGS15 #5 and #37): deferred consumers
# must not run mid-wave on a half-updated set of `Computed`s. A `Signal#value=`
# opens a propagation wave (`Reactive.propagate`); every leaf `Effect`/`Binding`
# woken during that wave must be deferred and flushed once, after the wave
# settles — never on an impossible pair of derived values that both descend from
# the same upstream signal. See REACTIVE.md.

private def rx_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false,
    optimization: Crysterm::OptimizationFlag::DamageTracking)
end

describe "Reactive glitch-free propagation" do
  # BUGS15 #5: a `Reactive.batch` opened and closed inside a `Changed` listener
  # that fires during a write's propagation wave must NOT flush the deferred
  # queue mid-wave.
  it "does not flush a batch closed inside an open propagation wave" do
    sig = Crysterm::Reactive::Signal.new 1
    c1 = Crysterm::Reactive::Computed(Int32).new { sig.value * 10 }
    c2 = Crysterm::Reactive::Computed(Int32).new { sig.value * 100 }

    runs = [] of Tuple(Int32, Int32)
    Crysterm::Reactive.effect { runs << {c1.value, c2.value} }
    runs.should eq [{10, 100}]

    # A user listener on c1 opens and closes an (empty) batch mid-wave.
    c1.on(Crysterm::Event::Changed) { Crysterm::Reactive.batch { } }

    sig.value = 2
    # Exactly one run, on the fully-settled pair. The impossible half-updated
    # {20, 100} must never appear, and the effect must not run twice.
    runs.should eq [{10, 100}, {20, 200}]
  end

  # BUGS15 #37: a `Binding` watching two `Computed`s over the same upstream
  # signal must run once per write, on the consistent pair — not mid-wave on a
  # glitched pair, and not twice.
  it "defers a Binding woken during a propagation wave until the wave settles" do
    scr = rx_screen
    w = Crysterm::Widget::Box.new parent: scr, width: 20, height: 3

    n = Crysterm::Reactive::Signal.new 1
    a = Crysterm::Reactive::Computed(Int32).new { n.value }
    b = Crysterm::Reactive::Computed(Int32).new { n.value }

    log = [] of Tuple(Int32, Int32)
    Crysterm::Reactive.bind(w, a, b) { log << {a.get, b.get} }
    log.should eq [{1, 1}] # binding runs once at bind time

    n.value = 2
    # One run for the write, on the settled pair — never the glitched {2, 1}.
    log.should eq [{1, 1}, {2, 2}]
  end
end
