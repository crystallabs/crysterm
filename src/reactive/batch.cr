module Crysterm
  module Reactive
    # Something that can be deferred to a batch flush and run once.
    module Deferrable
      abstract def run : Nil
    end

    # Batching groups a burst of signal writes so each affected binding runs
    # once, at the end of the batch, instead of on every intermediate write.
    # Outside a batch, bindings run synchronously on write; batching is an
    # optional *binding-run* dedup, not a prerequisite for correct rendering.
    #
    # Single-fiber: writes and flush must happen on one fiber, as this state is
    # unguarded.
    @@batch_depth = 0
    @@pending = [] of Deferrable
    # Membership index for @@pending, giving O(1) dedup in enqueue. Kept in
    # lock-step with @@pending.
    @@pending_set = Set(Deferrable).new

    # Depth of the active *propagation wave* — the synchronous cascade a single
    # `Signal#value=` sets off. Distinct from `@@batch_depth`: a wave is implicit
    # (opened by every write), a batch explicit. Both defer leaf `Effect`s.
    @@wave_depth = 0

    # Whether a `batch` is currently open on this fiber.
    def self.batching? : Bool
      @@batch_depth > 0
    end

    # Whether downstream leaf `Effect` runs must be deferred: either an explicit
    # `batch` or an in-flight propagation wave is open. Deferring until the wave
    # settles is what makes propagation glitch-free — an effect reading two
    # `Computed`s over a shared upstream `Signal` runs once, after *both* have
    # recomputed, never on a half-updated pair.
    def self.deferring? : Bool
      @@batch_depth > 0 || @@wave_depth > 0
    end

    # Runs *block* — the synchronous notification set off by one `Signal#value=` —
    # as a single propagation wave. `Computed`s recompute eagerly inside the wave
    # so their values settle, while dependent leaf `Effect`s are enqueued and
    # flushed once the outermost wave closes (unless a `batch` is still open,
    # which flushes at *its* close).
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
        # Both depths must be zero: a batch opened inside a `Changed` listener
        # during a write's wave must not flush mid-wave, which would run leaf
        # effects on a half-updated set of `Computed`s. The enclosing wave
        # performs the single flush once it settles.
        flush if @@batch_depth == 0 && @@wave_depth == 0
      end
    end

    # Runs every enqueued binding once and clears the queue. Called automatically
    # when the outermost `batch` closes.
    def self.flush : Nil
      return if @@pending.empty?
      pending = @@pending
      @@pending = [] of Deferrable
      @@pending_set.clear
      # Each item runs isolated: if one raises, the rest must still run. The
      # first exception is re-raised once the queue has drained.
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
