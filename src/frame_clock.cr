module Crysterm
  # A single phase-locked frame clock with optional tweening — the one place the
  # "spawn a fiber, do a bit of work, sleep, repeat" pattern lives.
  #
  # Everything that animates is built on this: `Timer` (a shared tick source, a
  # subclass — see below), `Window#every` (the demo animation helper),
  # `Widget::Effect::Animated` (the self-driven effects), and `Widget::Media`
  # frame playback all delegate their loop here instead of hand-rolling one.
  # Centralizing it means the drift correction (below) and the lifecycle
  # (`start`/`stop`/`toggle`/`running?`) are written — and fixed — once.
  #
  # Two shapes, picked by whether a `duration` is given:
  #
  # * **Ticker** (no duration) — calls the block every `interval`, forever, until
  #   `#stop`. This is what `Timer`, `every`, the effects and media playback use.
  #   The block can vary the cadence by assigning `#interval` (media uses this to
  #   honor each GIF frame's own delay), and end the run early by calling `#stop`.
  #
  # * **Tween** (a `duration`) — runs for that long, exposing eased progress in
  #   `#value` (0.0 → 1.0 through `#easing`) on each tick, then stops on its own.
  #   A consumer animating opacity reads `value` and maps it to its range. The
  #   final tick always lands on `value == 1.0`, so the end state is exact.
  #
  # ```
  # # ticker: cycle a hue every 100 ms
  # anim = Crysterm::FrameClock.new(0.1.seconds) { widget.phase += 0.02; widget.request_render }
  # anim.start
  # anim.stop
  #
  # # tween: fade a widget out over half a second (the block gets the clock)
  # Crysterm::FrameClock.new(0.03.seconds, duration: 0.5.seconds, easing: :in_out_sine) do |clock|
  #   widget.style.alpha = 1.0 - clock.value
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
    # Bumped on every `#start`. The loop fiber captures the generation it was
    # spawned for and exits if it no longer matches — so a `#stop` immediately
    # followed by a `#start` on the *same* instance (which re-sets `@running`
    # true before the old fiber observes the `stop`) can't leave two fibers
    # ticking the same clock.
    @generation : Int32 = 0
    @duration : Time::Span?
    @easing : Easing
    @on_tick : FrameClock ->
    @on_stop : (->)?

    # Creates a clock ticking *block* every *interval*. With a *duration* it
    # is a tween (see the class docs): it runs for *duration*, easing `#value`
    # with *easing*, then stops itself. Does not start until `#start`.
    #
    # The block is handed the `FrameClock` itself, so it can drive its own cadence
    # (`clock.interval = …`, e.g. per-frame GIF delays), end the run early
    # (`clock.stop`), or read `clock.value` — without needing an outside reference
    # to it. A block that needs none of that can just omit the parameter.
    def initialize(@interval : Time::Span, *, duration : Time::Span? = nil,
                   easing : Easing | Symbol = Easing::Linear, &@on_tick : FrameClock ->)
      @duration = duration
      @easing = easing.is_a?(Symbol) ? Easing.parse(easing.to_s) : easing
    end

    # Registers a callback fired once when the loop ends, for any reason (a tween
    # completing, `#stop`, or the fiber unwinding). Use `#completed?` inside it to
    # distinguish completion from cancellation. Returns self for chaining.
    def on_stop(&@on_stop : ->) : self
      self
    end

    # Starts the loop fiber. No-op if already running. Returns self for chaining.
    def start : self
      return self if running?

      # Reduced motion: collapse a *tween* to its final state instantly — one
      # tick at `value == 1.0`, then stop — instead of animating it. This makes
      # CSS transitions/fades land immediately. Tickers (decorative effects,
      # media playback, the shared `Timer`) have no duration and run normally.
      if @duration && Config.render_reduced_motion
        # Bump the generation even on this fiber-less path (the invariant is "on
        # every `#start`"): a previous run's fiber that was `#stop`ped but hasn't
        # yet observed it still holds the old generation. Without invalidating it,
        # when it next wakes it would match `@generation == gen` and fire `on_stop`
        # a *second* time — on top of the synchronous one below — if the
        # reduced-motion preference flipped on between that run's `#start` and this.
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
      # Phase-lock to a moving deadline instead of `sleep interval` after the
      # work: the latter makes the real period `interval + tick_work`, which
      # drifts slow and desyncs animations sharing a nominal clock.
      start_at = Time.instant
      next_at = start_at

      @fiber = Fiber.new do
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
            # Behind schedule (a slow tick, or the process was paused): resync the
            # phase to now rather than firing a burst of catch-up ticks.
            next_at = Time.instant
          end
        end

        # Only finalize if this fiber is still the current run: a superseded
        # fiber (a newer `#start` bumped `@generation`) must not clear the new
        # run's `@running` nor fire `on_stop` for it.
        if @generation == gen
          @running = false
          @on_stop.try &.call
        end
      end.enqueue

      self
    end

    # Cancels the loop. The fiber exits on its next check (it does not interrupt a
    # tick or a sleep in progress), then fires `#on_stop` with `#completed?` false.
    def stop : Nil
      @running = false
    end

    def toggle : Nil
      running? ? stop : start
    end
  end

  # A periodic tick source: a `FrameClock` that, instead of running one captured
  # block, *multicasts* `Event::Tick` to any number of subscribers.
  #
  # Its reason to exist is *sharing a clock*: pass one `Timer` to several widgets
  # and they advance in lockstep off a single fiber (one wakeup per tick, not one
  # per widget), and `stop`/`start` controls them all at once.
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
  #
  # All the timing machinery (the phase-locked loop, drift correction, lifecycle)
  # is inherited from `FrameClock`; `Timer` only swaps the single-block tick for
  # an `Event::Tick` broadcast.
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
