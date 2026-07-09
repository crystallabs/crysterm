module Crysterm
  module Reactive
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
    @@pending = [] of Binding

    # Whether a `batch` is currently open on this fiber.
    def self.batching? : Bool
      @@batch_depth > 0
    end

    # Records *binding* to run at the end of the current batch, deduplicated so a
    # binding woken by several writes still runs once.
    def self.enqueue(binding : Binding) : Nil
      @@pending << binding unless @@pending.includes? binding
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
      @@pending = [] of Binding
      pending.each &.run
    end
  end
end
