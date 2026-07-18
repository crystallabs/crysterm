module Crysterm
  module Reactive
    # Stack of effects currently executing (nested effects push/pop). The top is
    # the consumer that a `Signal#value` read registers against. Single-fiber:
    # this state is unguarded.
    @@current_stack = [] of Effect

    # Free-list of empty tracking scopes reused by `untracked`, so suspending
    # tracking allocates no throwaway `Array(Effect)` on a per-frame hot path.
    # Nesting is honored: each active `untracked` checks out a distinct array and
    # returns it cleared on exit. Grows only to the max nesting depth.
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
    # not register against the enclosing effect.
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
    # auto-discovers its dependencies each run and re-tracks, so a branch that
    # stops reading a signal stops depending on it. This is the tool for dynamic
    # dependency sets; prefer `bind` when the set is fixed.
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

      # Live subscriptions keyed by the object_id of the signal they watch, reused
      # across runs: a dep read again keeps its existing subscription, so a
      # stable-dependency effect allocates nothing on re-run.
      @subs_by_id = Hash(UInt64, ::Crysterm::Subscription).new
      # object_ids of signals read on the *current* run — dedups repeated reads
      # within one execution and drives removal of deps no longer read. Cleared,
      # not reallocated, at the start of each run.
      @tracked = Set(UInt64).new
      # object_ids first subscribed *during the current run*, so a raise mid-run
      # cancels exactly those and keeps the previous run's deps live. Cleared,
      # not reallocated, at the start of each run.
      @added = [] of UInt64
      # One shared change handler serving every dependency across every run, so
      # `track` builds no fresh closure per dep per re-run. Assigned in
      # `initialize` rather than as an ivar default because the closure calls the
      # instance method `schedule`, only in scope there.
      @on_change : Proc(::Crysterm::Event::Changed, ::Nil)
      getter? disposed = false

      # *eager* effects recompute synchronously the moment an upstream changes,
      # even mid-wave/mid-batch, instead of deferring to the flush — the basis of
      # glitch-free propagation for `Computed`. Ordinary effects are leaf
      # (non-eager).
      def initialize(@owner : ::Crysterm::Widget? = nil, *, @eager : Bool = false, &@block : ->)
        @on_change = ->(_e : ::Crysterm::Event::Changed) { schedule }
        run
      end

      # Registers *signal* as a dependency of this run (idempotent per run).
      # No-op once disposed: `dispose` can fire mid-run (e.g. the body tears
      # down the owner widget, whose `Event::Destroy` handler disposes this
      # effect), and reads after that point must not re-subscribe — `dispose`
      # already ran, so such a subscription could never be cancelled.
      def track(signal : SignalBase) : Nil
        return if disposed?
        id = signal.object_id
        return unless @tracked.add? id
        return if @subs_by_id.has_key? id # stable dep — keep its existing subscription
        sub = ::Crysterm::Subscription.new
        sub.on(signal, ::Crysterm::Event::Changed, &@on_change)
        @subs_by_id[id] = sub
        @added << id
      end

      # A tracked signal changed. An eager effect runs now, synchronously, so its
      # derived value settles within the current propagation wave. A leaf effect
      # is enqueued for the flush whenever a wave or batch is open, so it runs
      # exactly once, after every upstream `Computed` has settled.
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

      # Re-runs the effect: executes the body under this effect's tracking scope,
      # re-discovering its dependencies, then — only on success — cancels the
      # subscriptions for deps it no longer reads and schedules a repaint of the
      # owner's window. Deps stable across runs keep their existing subscription.
      #
      # The re-track is *transactional*: if the body raises, only the deps first
      # subscribed during this run are cancelled and every dep that predated it
      # stays live. Detaching up front instead would permanently drop every
      # dependency not re-read before the raise, silently freezing the effect
      # while `disposed?` still reads false.
      def run : Nil
        return if disposed?
        # Bags are reused in place, not reallocated per run.
        @tracked.clear
        @added.clear
        begin
          Reactive.with_current(self) { @block.call }
        rescue ex
          # Keep the last run's deps live: cancel only the subscriptions added
          # during this failed run.
          @added.each { |id| @subs_by_id.delete(id).try &.off }
          @added.clear
          raise ex
        end
        # A dispose that raced in mid-body (directly or via a nested run)
        # cleared the sub map at its point in time; cancel anything that
        # survived — subs added earlier in this same run before re-clearing, or
        # re-adds from a nested run — instead of re-tracking a dead effect.
        if disposed?
          @subs_by_id.each_value &.off
          @subs_by_id.clear
          @tracked.clear
          @added.clear
          return
        end
        # Drop subscriptions for deps not read this run. Fast path: matching
        # sizes mean @tracked (⊆ @subs_by_id) equals the live set, so a
        # stable-dependency effect neither allocates nor iterates.
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
