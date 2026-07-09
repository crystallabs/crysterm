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

      def initialize(@owner : ::Crysterm::Widget? = nil, &@block : ->)
        run
      end

      # Registers *signal* as a dependency of this run (idempotent per run).
      # Called from `Signal#value` while this effect is the active scope.
      def track(signal : SignalBase) : Nil
        return unless @tracked.add? signal.object_id
        @subs.on(signal, ::Crysterm::Event::Changed) { schedule }
      end

      # A tracked signal changed: run now, or defer to the batch flush.
      protected def schedule : Nil
        return if disposed?
        if Reactive.batching?
          Reactive.enqueue self
        else
          run
        end
      end

      # Re-runs the effect: drops last run's dependency subscriptions, executes
      # the body under this effect's tracking scope (which re-subscribes to
      # whatever it reads), then schedules a repaint of the owner's window.
      def run : Nil
        return if disposed?
        @subs.off
        @tracked.clear
        Reactive.with_current(self) { @block.call }
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
