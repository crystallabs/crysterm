module Crysterm
  module Reactive
    # Stack of effects currently executing (nested effects push/pop). The top is
    # the consumer that a `Signal#value` read registers against. Single-fiber for
    # Phase 1/2 — cross-fiber guarding is a deferred decision (see REACTIVE.md).
    @@current_stack = [] of Effect

    # Free-list of empty tracking scopes reused by `untracked`, so suspending
    # tracking does not heap-allocate a throwaway `Array(Effect)` per call (it
    # is invoked once per non-idempotent `Signal#value=` and per `Computed`
    # recompute-with-change — a per-frame hot path). Nesting is honored: each
    # active `untracked` checks out a distinct array, returning it (cleared) on
    # exit; `with_current` pushes/pops are balanced, so a checked-out scope is
    # empty again by the time it is returned. Grows only to the max nesting depth.
    @@untracked_pool = [] of Array(Effect)

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
    def self.untracked(& : -> U) : U forall U
      saved = @@current_stack
      scope = @@untracked_pool.pop? || [] of Effect
      @@current_stack = scope
      begin
        yield
      ensure
        @@current_stack = saved
        scope.clear
        @@untracked_pool << scope
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

      # Live subscriptions keyed by the object_id of the signal they watch. Reused
      # across runs: a dependency read again on the next run keeps its existing
      # subscription (no teardown/rebuild), so a stable-dependency effect allocates
      # nothing on re-run. Only genuinely added/dropped deps create/cancel a
      # `Subscription`. Replaces the per-run `Subscriptions` + `Set` bags.
      @subs_by_id = Hash(UInt64, ::Crysterm::Subscription).new
      # object_ids of signals read on the *current* run — dedups repeated reads of
      # the same signal within one execution and, after the run, drives removal of
      # deps no longer read. Cleared (not reallocated) at the start of each run.
      @tracked = Set(UInt64).new
      # object_ids first subscribed *during the current run* (not live before it),
      # so a raise mid-run can cancel exactly those and keep the previous run's
      # deps live. Cleared (not reallocated) at the start of each run.
      @added = [] of UInt64
      # One shared change handler serving every dependency across every run, so
      # `track` doesn't build a fresh `{ schedule }` closure per dep per re-run.
      # Assigned in `initialize` (not as an ivar default) because the closure
      # references the instance method `schedule`, which is only in scope there.
      @on_change : Proc(::Crysterm::Event::Changed, ::Nil)
      getter? disposed = false

      # *eager* effects recompute synchronously the moment an upstream changes,
      # even mid-wave/mid-batch, instead of deferring to the flush. `Computed`'s
      # internal recompute effect is eager so a derived value has *settled* before
      # any dependent leaf effect (which stays deferred) reads it — the basis of
      # glitch-free propagation. Ordinary effects are leaf (non-eager).
      def initialize(@owner : ::Crysterm::Widget? = nil, @eager : Bool = false, &@block : ->)
        @on_change = ->(_e : ::Crysterm::Event::Changed) { schedule }
        run
      end

      # Registers *signal* as a dependency of this run (idempotent per run).
      # Called from `Signal#value` while this effect is the active scope.
      def track(signal : SignalBase) : Nil
        id = signal.object_id
        return unless @tracked.add? id
        return if @subs_by_id.has_key? id # stable dep — keep its existing subscription
        sub = ::Crysterm::Subscription.new
        sub.on(signal, ::Crysterm::Event::Changed, &@on_change)
        @subs_by_id[id] = sub
        @added << id
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
      # (re-discovering its dependencies), then — only on success — cancels the
      # subscriptions for deps it no longer reads and schedules a repaint of the
      # owner's window. Deps stable across runs keep their existing subscription,
      # so an unchanged dependency set re-runs without any subscription churn.
      #
      # The re-track is *transactional*: if the body raises, only the deps first
      # subscribed during this run are cancelled and every dep that predated it is
      # kept live. Detaching up front instead would permanently drop every
      # dependency it didn't get to re-read before the raise — silently freezing
      # it (and any `Computed` built on it) while `disposed?` still reads false.
      def run : Nil
        return if disposed?
        # Reuse the tracking bags in place (no per-run reallocation): @tracked
        # records this run's reads, @added the deps first seen this run.
        @tracked.clear
        @added.clear
        begin
          Reactive.with_current(self) { @block.call }
        rescue ex
          # Keep last run's deps live: cancel only the subscriptions *added* this
          # (failed) run, leaving every dep that predated it untouched.
          @added.each { |id| @subs_by_id.delete(id).try &.off }
          @added.clear
          raise ex
        end
        # Drop subscriptions for deps not read this run. Fast path: if the sizes
        # match then @tracked (⊆ @subs_by_id) equals the live set — nothing to do,
        # so a stable-dependency effect touches no allocation and no iteration.
        if @subs_by_id.size != @tracked.size
          @subs_by_id.reject! do |id, sub|
            next false if @tracked.includes? id
            sub.off
            true
          end
        end
        @owner.try &.window?.try &.schedule_render
      end

      # Cancels all subscriptions and stops the effect. Idempotent.
      def dispose : Nil
        return if disposed?
        @disposed = true
        @subs_by_id.each_value &.off
        @subs_by_id.clear
        @tracked.clear
        @added.clear
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
