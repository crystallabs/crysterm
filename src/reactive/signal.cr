require "event_handler"

module Crysterm
  # Reactive state primitives — signals and bindings that let application state
  # drive widgets declaratively. See `REACTIVE.md` for the full design.
  #
  # The one notification mechanism is `event_handler`: a `Signal` is an emitter
  # that fires `Event::Changed`, and a binding (`Reactive.bind`) is a managed
  # subscription to it. Nothing here invents a second dispatch model.
  module Reactive
    # Non-generic base carrying the event-emitter machinery, so the generic
    # `Signal(T)` inherits `on`/`emit`/`off` without re-instantiating
    # `EventHandler` per type parameter — and so a heterogeneous set of signals
    # can be watched through one `SignalBase` reference (see `Reactive.bind`).
    abstract class SignalBase
      include EventHandler
    end

    # An observable value cell. Reading `#value` returns the current value;
    # assigning a *different* value emits `Event::Changed` (the single
    # notification model), waking any bindings watching this signal.
    #
    # Change-guarded exactly like `change_guarded_setter` /
    # `Action#notifying_setter`: assigning an `==` value is a no-op — no emit,
    # no repaint.
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
      # so it re-runs when this signal changes — the auto-tracking path. Outside
      # such a scope (the common `bind`/manual read), it is a plain read.
      def value : T
        Reactive.current?.try &.track(self)
        @value
      end

      # Assigns *v*. No-op (no notification, no repaint) if unchanged. Returns *v*.
      def value=(v : T) : T
        return v if @value == v
        @value = v
        # Emit with tracking suspended: listeners run synchronously, and a write
        # performed inside an effect/computed would otherwise leave the *writer*
        # on the scope stack while they execute — their signal reads would
        # register as spurious dependencies of the writer, re-running it on
        # unrelated changes. Bindings/listeners run with no active scope.
        Reactive.untracked { emit ::Crysterm::Event::Changed }
        v
      end

      # Call-style read, for symmetry with `#set`.
      def get : T
        @value
      end

      # Call-style write. Returns *v*.
      def set(v : T) : T
        self.value = v
      end

      # Replaces the value with the result of applying *block* to it. Convenience
      # for `sig.value = f(sig.value)` (e.g. `count.update { |n| n + 1 }`).
      def update(& : T -> T) : T
        self.value = yield @value
      end
    end
  end
end
