module Crysterm
  module Reactive
    # A derived signal: its value is produced by a block over other signals, and
    # it recomputes automatically when any of those change. Being a `SignalBase`,
    # it is itself readable and trackable, so derivations chain.
    #
    # Recomputation is an internal `Effect`, so the dependency set is discovered
    # and re-tracked the same way. `Event::Changed` is emitted only when the
    # result actually changes, so an equal recompute wakes nothing downstream.
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
        # Primed untracked, so initialization creates no dependency on the
        # enclosing scope; the effect below does the real tracked computation.
        @value = Reactive.untracked { @block.call }
        # Eager: recomputes synchronously the instant an upstream changes, so
        # this value has settled before any dependent leaf effect (deferred to
        # the wave's flush) reads it. That ordering keeps a diamond glitch-free.
        @effect = Effect.new(eager: true) do
          v = @block.call
          if @value != v
            @value = v
            # Tracking suspended: the internal effect is the active scope, so
            # listeners' signal reads would otherwise register as dependencies
            # of this computed.
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

      # Reads the current derived value without tracking: the running
      # `Effect`/`Computed` does not become a dependent. Does not force a
      # recompute — the internal eager effect keeps the value settled.
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
