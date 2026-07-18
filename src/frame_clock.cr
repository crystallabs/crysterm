module Crysterm
  # A phase-locked frame clock with optional tweening: a fiber that runs a block
  # on a drift-corrected cadence, with a `start`/`stop`/`toggle`/`running?`
  # lifecycle. Everything in Crysterm that animates is built on it.
  #
  # Two shapes, picked by whether a `duration` is given:
  #
  # * **Ticker** (no duration) — calls the block every `interval`, forever,
  #   until `#stop`. The block can vary cadence via `#interval` (media uses
  #   this for per-frame GIF delays) and end the run early via `#stop`.
  #
  # * **Tween** (a `duration`) — runs for that long, exposing eased progress in
  #   `#value` (0.0 → 1.0 through `#easing`) on each tick, then stops on its
  #   own. The final tick always lands on `value == 1.0`.
  #
  # ```
  # # ticker: cycle a hue every 100 ms
  # anim = Crysterm::FrameClock.new(0.1.seconds) { widget.phase += 0.02; widget.request_render }
  # anim.start
  # anim.stop
  #
  # # tween: fade a widget out over half a second (the block gets the clock)
  # Crysterm::FrameClock.new(0.03.seconds, duration: 0.5.seconds, easing: :in_out_sine) do |clock|
  #   widget.style.opacity = 1.0 - clock.value
  #   widget.request_render
  # end.start
  # ```
  class FrameClock
    # Delay between ticks. A ticker block may reassign this to change its own
    # cadence (e.g. per-frame GIF delays); the new value applies from the next
    # sleep on.
    property interval : Time::Span

    # Whether the loop fiber is currently running.
    getter? running = false

    # Whether the loop ended by reaching its `duration` (vs. being cancelled by
    # `#stop`). Always false for a ticker. Read it from an `#on_stop` callback to
    # tell a finished tween from a cancelled one.
    getter? completed = false

    # Eased progress of a tween (`0.0..1.0`); always `0.0` for a ticker. Valid to
    # read inside the tick block.
    getter value : Float64 = 0.0

    @fiber : Fiber?
    # Bumped on every `#start`. The loop fiber captures its generation and
    # exits if it no longer matches, so a `#stop` immediately followed by a
    # `#start` can't leave two fibers ticking the same clock.
    @generation : Int32 = 0
    @duration : Time::Span?
    @easing : Easing
    @on_tick : FrameClock ->
    @on_stop : (->)?

    # Creates a clock ticking *block* every *interval*. With a *duration* it is a
    # tween: runs for *duration*, easing `#value` with *easing*, then stops
    # itself. Does not start until `#start`.
    #
    # The block is handed the `FrameClock` itself, so it can drive its own cadence
    # (`clock.interval = …`), end the run early (`clock.stop`), or read
    # `clock.value`. A block needing none of that can omit the parameter.
    def initialize(@interval : Time::Span, *, duration : Time::Span? = nil,
                   easing : Easing | Symbol = Easing::Linear, &@on_tick : FrameClock ->)
      @duration = duration
      @easing = easing.is_a?(Symbol) ? Easing.parse(easing.to_s) : easing
    end

    # Registers a callback fired once when the loop ends, for any reason (a
    # tween completing, `#stop`, or the fiber unwinding). Use `#completed?`
    # inside it to distinguish completion from cancellation.
    def on_stop(&@on_stop : ->) : self
      self
    end

    # Starts the loop fiber. No-op if already running. Returns self for chaining.
    def start : self
      return self if running?

      # Reduced motion: collapse a tween to its final state instantly (one tick
      # at `value == 1.0`, then stop) so CSS transitions/fades land immediately.
      # Tickers have no duration and run normally.
      if @duration && Config.render_reduced_motion
        # Bump the generation even on this fiber-less path: a previous run's fiber
        # that was `#stop`ped but hasn't observed it yet still holds the old
        # generation, and would otherwise match on waking and fire `on_stop` twice.
        @generation += 1
        @completed = true
        @value = 1.0
        @on_tick.call self
        @on_stop.try &.call
        return self
      end

      @running = true
      @completed = false
      gen = (@generation += 1) # this run's identity; a superseding `#start` bumps it

      dur = @duration
      # Phase-lock to a moving deadline rather than `sleep interval` after the
      # work, which would make the real period `interval + tick_work` and desync
      # animations sharing a nominal clock.
      start_at = Time.instant
      next_at = start_at

      f = Fiber.new do
        loop do
          break unless @running && @generation == gen

          if dur
            elapsed = Time.instant - start_at
            raw = dur.zero? ? 1.0 : (elapsed.total_seconds / dur.total_seconds).clamp(0.0, 1.0)
            @value = @easing.apply(raw)
            @on_tick.call self
            if raw >= 1.0
              @running = false
              @completed = true
            end
          else
            @on_tick.call self
          end

          break unless @running && @generation == gen

          next_at += @interval
          delay = next_at - Time.instant
          if delay > Time::Span.zero
            sleep delay
          else
            # Behind schedule (slow tick, or process paused): resync the phase
            # to now instead of firing a burst of catch-up ticks.
            next_at = Time.instant
          end
        end

        # Only finalize if this fiber is still the current run: a superseded
        # fiber (a newer `#start` bumped `@generation`) must not clear the new
        # run's state.
        if @generation == gen
          @running = false
          @on_stop.try &.call
        end
      end
      @fiber = f
      f.enqueue

      self
    end

    # Cancels the loop. The fiber exits on its next check (does not interrupt a
    # tick/sleep in progress), then fires `#on_stop` with `#completed?` false.
    def stop : Nil
      @running = false
    end

    def toggle : Nil
      running? ? stop : start
    end
  end

  # A periodic tick source: a `FrameClock` that, instead of running one
  # captured block, multicasts `Event::Tick` to any number of subscribers.
  #
  # Pass one `Timer` to several widgets and they advance in lockstep off a single
  # fiber, with `stop`/`start` controlling them all at once.
  #
  # ```
  # clock = Crysterm::Timer.new 0.1.seconds      # one shared clock...
  # Widget::Gradient.new parent: s, ..., animate: clock
  # Widget::Gradient.new parent: s, ..., animate: clock   # ...in sync
  #
  # clock.stop   # pauses both
  # ```
  #
  # A widget given `animate: true` instead makes its own private `Timer`; one
  # given `animate: false` doesn't animate at all.
  class Timer < FrameClock
    include EventHandler

    # Creates a timer ticking every *interval*. Starts immediately unless
    # *autostart* is false (in which case call `#start` when ready).
    def initialize(interval : Time::Span = 0.1.seconds, *, autostart : Bool = true)
      super(interval) { emit Crysterm::Event::Tick }
      start if autostart
    end

    # Convenience: subscribe *block* to run on every tick.
    def on_tick(&block : ->)
      on(Crysterm::Event::Tick) { block.call }
    end
  end
end
