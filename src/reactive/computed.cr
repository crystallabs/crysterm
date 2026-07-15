module Crysterm
  module Reactive
    # A derived signal: its value is produced by a block over other signals, and
    # it recomputes automatically when any of those change. Being a `SignalBase`,
    # it is itself readable and trackable, so bindings/effects/other computeds can
    # depend on it — derivations chain.
    #
    # Recomputation is an internal `Effect` (auto-tracking + re-tracking), so a
    # `Computed`'s dependency set is discovered and kept current the same way. It
    # emits `Event::Changed` only when its result actually changes (guarded), so
    # a recompute that yields an equal value wakes nothing downstream.
    #
    # ```
    # n = Crysterm::Reactive::Signal.new 2
    # doubled = Crysterm::Reactive::Computed(Int32).new { n.value * 2 }
    # doubled.value # => 4
    # n.value = 5   # doubled recomputes to 10 and emits Changed
    # ```
    class Computed(T) < SignalBase
      @value : T
      getter? disposed = false

      def initialize(&@block : -> T)
        # Prime the value untracked so the assignment needed for initialization
        # doesn't create a spurious dependency on the enclosing scope. The effect
        # below then does the real, tracked computation.
        @value = Reactive.untracked { @block.call }
        # Eager: recompute synchronously the instant an upstream changes, so this
        # derived value has settled *before* any dependent leaf effect (deferred
        # to the wave's flush) reads it. That ordering is what makes propagation
        # glitch-free for a diamond (two computeds sharing one upstream signal).
        @effect = Effect.new(eager: true) do
          v = @block.call
          if @value != v
            @value = v
            # Emit with tracking suspended: the internal effect is the active
            # scope here, so listeners' signal reads would otherwise register
            # as spurious dependencies of this computed (see `Signal#value=`).
            Reactive.untracked { emit ::Crysterm::Event::Changed }
          end
        end
      end

      # Reads the current derived value, registering a dependency if read inside
      # an effect/computed (same tracking as `Signal#value`).
      def value : T
        Reactive.current?.try &.track(self)
        @value
      end

      # Reads the current derived value *without* tracking (same non-tracking
      # read as `Signal#peek`): the running `Effect`/`Computed` does not become
      # a dependent. Does not force a recompute — the internal eager effect
      # keeps `@value` settled.
      def peek : T
        @value
      end

      # Stops recomputing and releases the internal effect's subscriptions.
      def dispose : Nil
        return if disposed?
        @disposed = true
        @effect.dispose
      end
    end
  end
end
