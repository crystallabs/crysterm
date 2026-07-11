module Crysterm
  module Reactive
    # Stack of effects currently executing (nested effects push/pop). The top is
    # the consumer that a `Signal#value` read registers against. Single-fiber for
    # Phase 1/2 — cross-fiber guarding is a deferred decision (see REACTIVE.md).
    @@current_stack = [] of Effect

    # The effect currently running, if any (the top of the tracking stack).
    def self.current? : Effect?
      @@current_stack.last?
    end

    # Runs *block* with *effect* as the active tracking scope, restoring the
    # previous scope afterward. Signal reads inside register against *effect*.
    def self.with_current(effect : Effect, &)
      @@current_stack.push effect
      begin
        yield
      ensure
        @@current_stack.pop
      end
    end

    # Runs *block* with dependency tracking suspended, so signal reads inside do
    # NOT register against the enclosing effect. Used for the priming read in
    # `Computed` and available for any read that should not create a dependency.
    def self.untracked(&block : -> U) : U forall U
      saved = @@current_stack
      @@current_stack = [] of Effect
      begin
        block.call
      ensure
        @@current_stack = saved
      end
    end

    # A side effect that re-runs whenever any signal it *read on its last run*
    # changes. Unlike `Binding` (a fixed, explicitly-named set), an `Effect`
    # **auto-discovers** its dependencies each run and **re-tracks** — it drops
    # the previous run's subscriptions and rebuilds from what was actually read,
    # so a branch that stops reading a signal stops depending on it (no stale
    # re-runs). This is the tool for dynamic dependency sets; prefer `bind` when
    # the set is fixed. See REACTIVE.md.
    #
    # ```
    # Crysterm::Reactive.effect { label.content = show.value ? a.value : b.value }
    # ```
    #
    # Pass an *owner* widget to (a) schedule a repaint of its window after each
    # run and (b) auto-dispose when it emits `Event::Destroy` (via
    # `Reactive.effect`).
    class Effect
      include Deferrable

      @subs = ::Crysterm::Subscriptions.new
      # object_ids of signals already subscribed this run — dedups repeated reads
      # of the same signal within one execution.
      @tracked = Set(UInt64).new
      getter? disposed = false

      # *eager* effects recompute synchronously the moment an upstream changes,
      # even mid-wave/mid-batch, instead of deferring to the flush. `Computed`'s
      # internal recompute effect is eager so a derived value has *settled* before
      # any dependent leaf effect (which stays deferred) reads it — the basis of
      # glitch-free propagation. Ordinary effects are leaf (non-eager).
      def initialize(@owner : ::Crysterm::Widget? = nil, @eager : Bool = false, &@block : ->)
        run
      end

      # Registers *signal* as a dependency of this run (idempotent per run).
      # Called from `Signal#value` while this effect is the active scope.
      def track(signal : SignalBase) : Nil
        return unless @tracked.add? signal.object_id
        @subs.on(signal, ::Crysterm::Event::Changed) { schedule }
      end

      # A tracked signal changed. An *eager* effect (a `Computed`'s recompute)
      # runs now, synchronously, so its derived value settles within the current
      # propagation wave. A leaf effect defers — enqueued for the flush — whenever
      # a wave or batch is open (`deferring?`), so it runs exactly once, after
      # every upstream `Computed` in the wave has settled (no glitch, no double
      # run); otherwise it runs now.
      protected def schedule : Nil
        return if disposed?
        if @eager
          run
        elsif Reactive.deferring?
          Reactive.enqueue self
        else
          run
        end
      end

      # Re-runs the effect: executes the body under this effect's tracking scope
      # (re-discovering its dependencies into a fresh subscription bag), then —
      # only on success — drops the previous run's subscriptions and schedules a
      # repaint of the owner's window.
      #
      # The re-track is *transactional*: if the body raises, the partially-built
      # new subscriptions are torn down and the previous run's are kept. Clearing
      # up front instead would permanently detach the effect from every
      # dependency it didn't get to re-read before the raise — silently freezing
      # it (and any `Computed` built on it) while `disposed?` still reads false.
      def run : Nil
        return if disposed?
        old_subs = @subs
        old_tracked = @tracked
        @subs = ::Crysterm::Subscriptions.new
        @tracked = Set(UInt64).new
        begin
          Reactive.with_current(self) { @block.call }
        rescue ex
          @subs.off        # drop the partial re-track...
          @subs = old_subs # ...and keep last run's deps live
          @tracked = old_tracked
          raise ex
        end
        old_subs.off
        @owner.try &.window?.try &.schedule_render
      end

      # Cancels all subscriptions and stops the effect. Idempotent.
      def dispose : Nil
        return if disposed?
        @disposed = true
        @subs.off
        @tracked.clear
      end
    end

    # Creates an `Effect`. Runs once immediately (discovering its dependencies),
    # then re-runs on any change to a signal it read. If *owner* is given, the
    # effect schedules a repaint of *owner*'s window after each run and disposes
    # automatically when *owner* is destroyed. Returns the `Effect`.
    def self.effect(owner : ::Crysterm::Widget? = nil, &block : ->) : Effect
      eff = Effect.new owner, &block
      owner.try &.on(::Crysterm::Event::Destroy) { eff.dispose }
      eff
    end
  end
end
