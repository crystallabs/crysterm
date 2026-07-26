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

      # Registers this signal as a dependency of the running `Effect`/`Computed`,
      # if any — the single place the read-tracking contract lives. Called at the
      # top of every concrete `#value` reader (`Signal#value`, `Computed#value`).
      # A no-op outside a tracking scope.
      protected def register_read : Nil
        Reactive.current?.try &.track(self)
      end

      # Subscribes *block* to this signal's `Event::Changed` — sugar over
      # `on(Event::Changed) { ... }`, hiding the internal event class. Inherited
      # by `Signal`/`Computed`, so either can be watched without touching `on`
      # directly.
      #
      # `Event::Changed` carries no payload (unlike e.g. `Event::TextChanged`),
      # so *block* takes none — call `#value`/`#peek` inside it for the new
      # value.
      #
      # ```
      # count = Crysterm::Reactive::Signal.new 0
      # count.on_change { puts "now #{count.value}" }
      # count.value = 5 # => "now 5"
      # ```
      def on_change(&block : ->) : Nil
        on(::Crysterm::Event::Changed) { block.call }
      end
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
        register_read
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

    # Creates a `Signal` seeded with *value*. Factory beside `Reactive.effect`/
    # `Reactive.bind`, so the `signal`/`computed`/`effect` family reads
    # consistently instead of spelling out `Signal(T).new` on its own.
    #
    # ```
    # count = Crysterm::Reactive.signal 0
    # ```
    def self.signal(value : T) : Signal(T) forall T
      Signal.new value
    end
  end
end
