module Crysterm
  module Reactive
    # Something that can be deferred to a batch flush and run once. Implemented
    # by both `Binding` (permanent) and `Effect` (re-tracking), so one queue
    # dedups either kind across a burst of writes.
    module Deferrable
      abstract def run : Nil
    end

    # Batching groups a burst of signal writes so each affected binding runs
    # once, at the end of the batch, instead of on every intermediate write.
    #
    # Outside a batch, bindings run synchronously on write — correct on its own,
    # since the render doorbell (`Window#schedule_render`) already coalesces the
    # resulting frames. Batching is therefore an optional *binding-run* dedup for
    # multi-write turns, not a prerequisite for correct rendering.
    #
    # Single-fiber for Phase 1 (writes and flush happen on one fiber). Guarding
    # the shared state for cross-fiber writes is a deferred decision — see the
    # threading note in `REACTIVE.md`.
    @@batch_depth = 0
    @@pending = [] of Deferrable
    # Membership index for @@pending, so enqueue dedups in O(1) instead of an
    # O(n) linear scan (a burst enqueuing m distinct consumers was O(m^2)).
    # Kept in lock-step with @@pending: added in enqueue, cleared in flush.
    @@pending_set = Set(Deferrable).new

    # Depth of the active *propagation wave* — the synchronous cascade a single
    # `Signal#value=` sets off (`Reactive.propagate`). Kept distinct from
    # `@@batch_depth` because a wave is implicit (opened by every write) while a
    # batch is explicit (opened by `Reactive.batch`). Both defer leaf `Effect`s.
    @@wave_depth = 0

    # Whether a `batch` is currently open on this fiber.
    def self.batching? : Bool
      @@batch_depth > 0
    end

    # Whether downstream leaf `Effect` runs must be deferred: either an explicit
    # `batch` or an in-flight propagation `wave` is open. During a wave, deferring
    # a leaf effect until the wave settles is what makes propagation glitch-free —
    # an effect reading two `Computed`s over a shared upstream `Signal` runs once,
    # after *both* have recomputed, never on an impossible half-updated pair.
    def self.deferring? : Bool
      @@batch_depth > 0 || @@wave_depth > 0
    end

    # Runs *block* — the synchronous notification set off by one `Signal#value=` —
    # as a single propagation wave. `Computed`s recompute eagerly inside the wave
    # (so their values settle), but each dependent leaf `Effect` is enqueued
    # rather than run, and the whole enqueued set flushes once the outermost wave
    # closes (unless a `batch` is still open, which flushes at *its* close). This
    # is the glitch-free scheduling guarantee — see `deferring?`.
    def self.propagate(&) : Nil
      @@wave_depth += 1
      begin
        yield
      ensure
        @@wave_depth -= 1
        flush if @@wave_depth == 0 && @@batch_depth == 0
      end
    end

    # Records *item* to run at the end of the current batch, deduplicated so a
    # binding/effect woken by several writes still runs once.
    def self.enqueue(item : Deferrable) : Nil
      @@pending << item if @@pending_set.add? item
    end

    # Runs *block* with binding execution deferred until it returns. Nesting is
    # supported; only the outermost `batch` flushes.
    #
    # ```
    # Reactive.batch do
    #   first_name.value = "Ada"
    #   last_name.value = "Lovelace"
    # end # a binding on both names runs once here, not twice
    # ```
    def self.batch(&) : Nil
      @@batch_depth += 1
      begin
        yield
      ensure
        @@batch_depth -= 1
        flush if @@batch_depth == 0
      end
    end

    # Runs every enqueued binding once and clears the queue. Called automatically
    # when the outermost `batch` closes.
    def self.flush : Nil
      return if @@pending.empty?
      pending = @@pending
      @@pending = [] of Deferrable
      @@pending_set.clear
      # Run each deferred item isolated: if one raises, the rest must still run
      # (otherwise every binding queued after it is silently discarded). Remember
      # the first exception and re-raise it after the whole queue has drained.
      first_ex = nil
      pending.each do |item|
        begin
          item.run
        rescue ex
          first_ex ||= ex
        end
      end
      raise first_ex if first_ex
    end
  end
end
