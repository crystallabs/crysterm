module Crysterm
  # A phase-locked frame clock with optional tweening: a fiber that runs a block
  # on a drift-corrected cadence, with a `start`/`stop`/`toggle`/`running?`
  # lifecycle. Everything in Crysterm that animates is built on it.
  #
  # Two shapes, each with its own named constructor:
  #
  # * **`.ticker`** — calls the block every `interval`, forever, until `#stop`.
  #   The block can vary cadence via `#interval` (media uses this for
  #   per-frame GIF delays) and end the run early via `#stop`.
  #
  # * **`.tween`** — runs for a `duration`, exposing eased progress in
  #   `#value` (0.0 → 1.0 through its easing) on each tick, then stops on its
  #   own. The final tick always lands on `value == 1.0`.
  #
  # ```
  # # ticker: cycle a hue every 100 ms
  # anim = Crysterm::FrameClock.ticker(0.1.seconds) { widget.phase += 0.02; widget.update! }
  # anim.start
  # anim.stop
  #
  # # tween: fade a widget out over half a second (the block gets the clock)
  # Crysterm::FrameClock.tween(0.03.seconds, duration: 0.5.seconds, easing: :in_out_sine) do |clock|
  #   widget.style.opacity = 1.0 - clock.value
  #   widget.update!
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
    # `#stop`). Always false for a ticker. Read it from an `#stop_handler` callback to
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
    @immediate : Bool = true
    @on_tick : FrameClock ->
    @stop_handler : (->)?

    # Seconds elapsed since *start_at* (a `Time.instant` reading), driving progress
    # from real wall-clock time rather than a fixed per-tick step — `FrameClock`
    # drops catch-up ticks when behind, so an accumulator would undercount them.
    def self.elapsed_since(start_at : Time::Instant) : Float64
      (Time.instant - start_at).total_seconds
    end

    # Creates a repeating clock (a "ticker"): ticks *block* every *interval*,
    # forever, until `#stop`. Does not start until `#start`.
    #
    # The block is handed the `FrameClock` itself, so it can drive its own cadence
    # (`clock.interval = …`) or end the run early (`clock.stop`). A block
    # needing neither can omit the parameter.
    #
    # By default (*immediate* true) the block also fires once at t≈0, before the
    # first sleep — the usual "tick now, then every interval" ticker shape. Pass
    # *immediate: false* for a "first tick at t≈interval" shape instead (a
    # one-shot delay, or a feeder whose t=0 frame is produced some other way):
    # the loop performs its `next_at += interval; sleep` phase step once, up
    # front, before the first tick fires — phase-lock is unaffected, since
    # `next_at` derives from the start time regardless.
    def self.ticker(interval : Time::Span, *, immediate : Bool = true,
                    &block : FrameClock ->) : FrameClock
      new(interval, nil, Easing::Linear, immediate, &block)
    end

    # Creates a duration-bound clock (a "tween"): ticks *block* every
    # *interval* for *duration*, easing `#value` (0.0 → 1.0) with *easing* on
    # each tick, then stops itself — the final tick always lands on
    # `value == 1.0`. Does not start until `#start`.
    #
    # The block is handed the `FrameClock` itself, to read `clock.value` (or
    # cancel early via `clock.stop`; register a `#stop_handler` and check
    # `#completed?` to tell the two ends apart).
    #
    # A tween always ticks once at t≈0, to seed `#value` at `raw == 0` — which
    # is why there is no *immediate* choice here: the delayed tween the old
    # `new(immediate: false, duration: …)` spelling could ask for (and then
    # reject at runtime) is now unconstructible.
    def self.tween(interval : Time::Span, *, duration : Time::Span,
                   easing : Easing | Symbol = Easing::Linear,
                   &block : FrameClock ->) : FrameClock
      new(interval, duration, easing.is_a?(Symbol) ? Easing.parse(easing.to_s) : easing, true, &block)
    end

    # The named constructors — `.ticker`/`.tween` here, plus `Timer.new`/
    # `.single_shot`/`.every` — are the public entry points; each exposes only
    # the parameters valid for its shape.
    private def initialize(@interval : Time::Span, @duration : Time::Span?,
                           @easing : Easing, @immediate : Bool, &@on_tick : FrameClock ->)
    end

    # Registers a callback fired once when the loop ends, for any reason (a
    # tween completing, `#stop`, or the fiber unwinding). Use `#completed?`
    # inside it to distinguish completion from cancellation.
    def stop_handler(&@stop_handler : ->) : self
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
        # generation, and would otherwise match on waking and fire `stop_handler` twice.
        @generation += 1
        @completed = true
        @value = 1.0
        @on_tick.call self
        @stop_handler.try &.call
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
        unless @immediate
          # First tick at t≈interval instead of t≈0: take the phase step (see
          # `.ticker`) before entering the loop below, which otherwise
          # always ticks first and sleeps second. `@duration` is nil here
          # (only `.ticker` exposes *immediate*), so this only ever runs for
          # tickers.
          next_at += @interval
          delay = next_at - Time.instant
          if delay > Time::Span.zero
            sleep delay
          else
            next_at = Time.instant
            Fiber.yield
          end
        end

        loop do
          break unless @running && @generation == gen

          if dur
            elapsed = Time.instant - start_at
            raw = dur.zero? ? 1.0 : (elapsed.total_seconds / dur.total_seconds).clamp(0.0, 1.0)
            @value = @easing.apply(raw)
            run_tick
            if raw >= 1.0
              @running = false
              @completed = true
            end
          else
            run_tick
          end

          break unless @running && @generation == gen

          next_at += @interval
          delay = next_at - Time.instant
          if delay > Time::Span.zero
            sleep delay
          else
            # Behind schedule (slow tick, or process paused): resync the phase
            # to now instead of firing a burst of catch-up ticks. Still yield,
            # or this branch would loop into the next tick with no blocking
            # operation and — fibers being cooperative — monopolize the thread,
            # starving the render/input fibers for as long as the overload lasts.
            next_at = Time.instant
            Fiber.yield
          end
        end
      ensure
        # Only finalize if this fiber is still the current run: a superseded
        # fiber (a newer `#start` bumped `@generation`) must not clear the new
        # run's state. Inside an `ensure` so the fiber unwinding (anything the
        # tick isolation above doesn't cover) cannot skip it — the `#stop_handler`
        # contract promises firing for *any* end of the loop, and a skipped
        # finalize leaves `@running` stuck `true` (`#start` no-ops forever)
        # with the stop callback lost.
        if @generation == gen
          @running = false
          @stop_handler.try &.call
        end
      end
      @fiber = f
      f.enqueue

      self
    end

    # Cancels the loop. The fiber exits on its next check (does not interrupt a
    # tick/sleep in progress), then fires `#stop_handler` with `#completed?` false.
    def stop : Nil
      @running = false
    end

    def toggle : Nil
      running? ? stop : start
    end

    # Runs the tick block, isolating its exceptions: one raising tick must not
    # unwind the loop fiber — dumping a backtrace over the live TUI and, for a
    # shared `Timer`, killing the tick source for every subscriber at once.
    # Mirrors the per-event rescue in the input fiber (`Screen#start_input`)
    # and the per-job rescue in `Window`'s UI-queue drain.
    private def run_tick : Nil
      @on_tick.call self
    rescue ex
      ::Log.error(exception: ex) { "Crysterm: FrameClock tick raised; continuing" }
    end
  end

  # A periodic tick source: a `FrameClock` that, instead of running one
  # captured block, multicasts `Event::Tick` to any number of subscribers.
  #
  # Pass one `Timer` to several widgets and they advance in lockstep off a single
  # fiber, with `stop`/`start` controlling them all at once.
  #
  # ```
  # clock = Crysterm::Timer.new(0.1.seconds).start   # one shared clock...
  # Widget::Gradient.new parent: s, ..., animate: clock
  # Widget::Gradient.new parent: s, ..., animate: clock   # ...in sync
  #
  # clock.stop   # pauses both
  # ```
  #
  # A widget given `animate: true` instead makes its own private `Timer`; one
  # given `animate: false` doesn't animate at all.
  #
  # The `.single_shot`/`.every` conveniences wrap a block instead of asking
  # for subscriptions — they are what `Window#after`/`#every` delegate to.
  class Timer < FrameClock
    include EventHandler

    # Creates a timer ticking every *interval*. Like `QTimer`, it does not
    # start until `#start` (which returns `self`, so
    # `Timer.new(0.1.seconds).start` builds and starts in one go).
    #
    # By default the first tick fires at t≈0 once started; pass
    # *immediate: false* for a first tick at t≈interval instead (see
    # `FrameClock.ticker`).
    def initialize(interval : Time::Span = 0.1.seconds, *, immediate : Bool = true)
      super(interval, nil, Easing::Linear, immediate) { emit Crysterm::Event::Tick }
    end

    # One-shot timer (`QTimer.singleShot` analog): runs *block* once, after
    # *span* has elapsed, then stops itself. Returns the already-started
    # `Timer`, so the caller can `#stop` it to cancel before it fires.
    # `Window#after` is this plus a render.
    def self.single_shot(span : Time::Span, &block : ->) : Timer
      t = new(span, immediate: false)
      t.on(Crysterm::Event::Tick) do
        t.stop # before the block, so a block that re-arms the timer wins
        block.call
      end
      t.start
    end

    # Repeating convenience: runs *block* immediately and then every *span*,
    # until stopped. Returns the already-started `Timer` — and hands it to the
    # block too, so a repeater can stop itself without the
    # forward-declared-nilable-local dance:
    #
    # ```
    # Timer.every(35.milliseconds) do |t|
    #   step_progress
    #   t.stop if done?
    # end
    # ```
    #
    # With *times*, stops by itself after that many calls. `Window#every` is
    # this plus a render.
    def self.every(span : Time::Span, *, times : Int32? = nil, &block : Timer ->) : Timer
      raise ArgumentError.new "Timer.every: times must be >= 1" if times && times < 1
      t = new(span)
      calls = 0
      t.on(Crysterm::Event::Tick) do
        block.call t
        t.stop if times && (calls += 1) >= times
      end
      t.start
    end

    # Convenience: subscribe *block* to run on every tick.
    def on_tick(&block : ->)
      on(Crysterm::Event::Tick) { block.call }
    end
  end
end
