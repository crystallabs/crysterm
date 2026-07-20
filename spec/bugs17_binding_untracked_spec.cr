require "./spec_helper"

include Crysterm

# Regression spec for BUGS17 B17-36: deferred `Binding` runs must execute
# outside the writing effect's tracking scope.
#
# BUGS13 R4 established that `Signal#value=` emits `Changed` untracked so a
# synchronous listener's reads don't subscribe as dependencies of the writing
# effect. But that untracked window closes before the wave-close `flush` drains
# deferred `Binding`s (`Reactive.flush`, src/reactive/batch.cr). When the write
# happens during an effect's synchronous run — notably the initial run inside
# `Effect#initialize` — that effect is still on the tracking-scope stack while
# the flush runs the binding's block with no scope management of its own, so
# every signal the binding reads is silently subscribed as a dependency of the
# WRITING effect. A later unrelated write then spuriously re-runs that effect.
#
# The fix wraps the drained item's `run` in `Reactive.untracked` in `flush`.

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

describe "BUGS17 B17-36 — deferred Binding runs outside the writer effect's scope" do
  it "does not make a binding's read a dependency of the effect that wrote its signal" do
    scr = rx_screen
    w = Crysterm::Widget::Box.new parent: scr, width: 20, height: 3

    s = Crysterm::Reactive::Signal.new 0
    other = Crysterm::Reactive::Signal.new 0
    src = Crysterm::Reactive::Signal.new 0

    # Bindings first, effects second (normal app init order). The binding reads
    # both `s` and the unrelated `other`.
    bound = [] of Tuple(Int32, Int32)
    Crysterm::Reactive.bind(w, s, other) { bound << {s.value, other.value} }
    bound.should eq [{0, 0}] # binding runs once at bind time

    # The writer effect writes `s` during its initial run (inside Effect.new).
    # The wave-close flush then runs the binding while the writer is still on
    # the tracking-scope stack — under the bug, the binding's reads of `s` and
    # `other` are subscribed as dependencies of the writer.
    runs = 0
    Crysterm::Reactive::Effect.new do
      runs += 1
      s.value = src.value + 1
    end
    runs.should eq 1

    # An unrelated write to `other`. It must NOT re-run the writer effect; only
    # the binding (which legitimately watches `other`) should respond.
    other.value = 5
    runs.should eq 1
  end
end
