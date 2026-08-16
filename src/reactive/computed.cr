module Crysterm
  module Reactive
    # A derived property: its value is produced by a block over other properties, and
    # it recomputes automatically when any of those change. Being a `PropertyBase`,
    # it is itself readable and trackable, so derivations chain.
    #
    # Recomputation is an internal `Effect`, so the dependency set is discovered
    # and re-tracked the same way. `Event::ReactiveChanged` is emitted only when the
    # result actually changes, so an equal recompute wakes nothing downstream.
    #
    # ```
    # n = Crysterm::Reactive::Property.new 2
    # doubled = Crysterm::Reactive::Computed(Int32).new { n.value * 2 }
    # doubled.value # => 4
    # n.value = 5   # doubled recomputes to 10 and emits Changed
    # ```
    class Computed(T) < PropertyBase
      @value : T
      getter? disposed = false

      def initialize(&@block : -> T)
        # No untracked prime: the effect's *own* first run both discovers the
        # dependencies and produces the value, so priming would only run the
        # derivation a second time for nothing.
        #
        # Leaving the slot uninitialized until that run is safe: `Effect.new`
        # performs its initial run synchronously (from its own `initialize`),
        # so on the success path `@value` is assigned before this constructor
        # returns, and nothing can observe it earlier — the first run does not
        # `emit`, so there are no listeners to re-enter through, and no
        # reference to `self` has escaped yet. If the first run raises, the
        # constructor raises too: `Effect#run`'s transactional rescue has
        # already cancelled every subscription that run added (on a first run
        # that is all of them), and the half-built `Computed` is unreachable.
        # A conservatively-scanned slot that never held a real reference costs
        # at worst transient over-retention, never a crash (and Crystal's
        # allocator hands back zeroed memory anyway).
        @value = uninitialized T
        # `primed` exists so `@value != v` is only ever reached from the second
        # run on — the uninitialized slot must never be compared.
        primed = false
        # Eager: recomputes synchronously the instant an upstream changes, so
        # this value has settled before any dependent leaf effect (deferred to
        # the wave's flush) reads it. That ordering keeps a diamond glitch-free.
        @effect = Effect.new(eager: true) do
          v = @block.call
          if !primed
            primed = true
            @value = v
          elsif @value != v
            @value = v
            # Tracking suspended: the internal effect is the active scope, so
            # listeners' property reads would otherwise register as dependencies
            # of this computed.
            Reactive.untracked { emit ::Crysterm::Event::ReactiveChanged }
          end
        end
      end

      # Reads the current derived value, registering a dependency if read inside
      # an effect/computed (same tracking as `Property#value`).
      def value : T
        register_read
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

    # Creates a `Computed` deriving its value from *block*. Factory beside
    # `Reactive.property`/`Reactive.effect`, completing the family — and, unlike
    # `Computed(T).new`, infers `T` from the block's return type instead of
    # requiring it spelled out at the call site.
    #
    # ```
    # n = Crysterm::Reactive.property 2
    # doubled = Crysterm::Reactive.computed { n.value * 2 }
    # doubled.value # => 4
    # ```
    def self.computed(&block : -> U) : Computed(U) forall U
      Computed(U).new(&block)
    end
  end
end
