require "event_handler"

module Crysterm
  # Reactive state primitives — signals and bindings that let application state
  # drive widgets declaratively.
  #
  # The one notification mechanism is `event_handler`: a `Signal` is an emitter
  # that fires `Event::Changed`, and a binding (`Reactive.bind`) is a managed
  # subscription to it. There is no second dispatch model.
  module Reactive
    # Non-generic base carrying the event-emitter machinery, so `Signal(T)`
    # inherits `on`/`emit`/`off` without re-instantiating `EventHandler` per type
    # parameter, and so a heterogeneous set of signals can be watched through one
    # reference.
    abstract class SignalBase
      include EventHandler
    end

    # An observable value cell. Reading `#value` returns the current value;
    # assigning a *different* value emits `Event::Changed` (the single
    # notification model), waking any bindings watching this signal.
    #
    # Change-guarded: assigning an `==` value is a no-op — no emit, no repaint.
    #
    # ```
    # count = Crysterm::Reactive::Signal.new 0
    # count.value     # => 0
    # count.value = 5 # emits Event::Changed
    # count.value = 5 # no-op (unchanged)
    # ```
    class Signal(T) < SignalBase
      @value : T

      def initialize(@value : T)
      end

      # Reads the current value. If a dependency-tracking scope is active (an
      # `Effect`/`Computed` is running), registers that consumer as a dependent
      # so it re-runs when this signal changes. Outside such a scope, a plain read.
      def value : T
        Reactive.current?.try &.track(self)
        @value
      end

      # Assigns *v*. No-op (no notification, no repaint) if unchanged. Returns *v*.
      def value=(v : T) : T
        return v if @value == v
        @value = v
        # One propagation *wave*: dependent `Computed`s recompute eagerly inside
        # it so their values settle, while each dependent leaf `Effect` is
        # deferred until the wave closes — glitch-free, so an effect reading two
        # computeds over this signal runs once, on a consistent pair. Tracking is
        # suspended for the emit: a write performed inside an effect/computed
        # would otherwise leave the *writer* on the scope stack, and listeners'
        # signal reads would register as spurious dependencies of it.
        Reactive.propagate { Reactive.untracked { emit ::Crysterm::Event::Changed } }
        v
      end

      # Reads the current value *without* registering the running
      # `Effect`/`Computed` as a dependent. Use wherever a read must not create a
      # dependency — notably a setter's own change guard, which would otherwise
      # make an effect that writes a property depend on it and re-run itself.
      def peek : T
        @value
      end

      # Replaces the value with the result of applying *block* to it, e.g.
      # `count.update { |n| n + 1 }`.
      def update(& : T -> T) : T
        self.value = yield @value
      end
    end
  end
end
