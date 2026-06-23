module Crysterm
  # A single phase-locked frame clock with optional tweening — the one place the
  # "spawn a fiber, do a bit of work, sleep, repeat" pattern lives.
  #
  # Everything that animates is built on this: `Timer` (a shared tick source),
  # `Screen#every` (the demo animation helper), `Widget::Effect::Animated` (the
  # self-driven effects), and `Widget::Media` frame playback all delegate their
  # loop here instead of hand-rolling one. Centralizing it means the drift
  # correction (below) and the lifecycle (`start`/`stop`/`toggle`/`running?`) are
  # written — and fixed — once.
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
  # anim = Crysterm::Animation.new(0.1.seconds) { widget.phase += 0.02; widget.request_render }
  # anim.start
  # anim.stop
  #
  # # tween: fade a widget out over half a second (the block gets the clock)
  # Crysterm::Animation.new(0.03.seconds, duration: 0.5.seconds, easing: :in_out_sine) do |clock|
  #   widget.style.alpha = 1.0 - clock.value
  #   widget.request_render
  # end.start
  # ```
  class Animation
    # Easing curves mapping linear progress (`0.0..1.0`) to eased progress
    # (`0.0..1.0`). `Linear` is the identity; the rest accelerate (`In`),
    # decelerate (`Out`), or both (`InOut`).
    enum Easing
      Linear
      InQuad
      OutQuad
      InOutQuad
      InCubic
      OutCubic
      InOutCubic
      InOutSine

      # Applies the curve to *t* (clamped `0.0..1.0` by the caller).
      def apply(t : Float64) : Float64
        case self
        in Easing::Linear     then t
        in Easing::InQuad     then t * t
        in Easing::OutQuad    then t * (2.0 - t)
        in Easing::InOutQuad  then t < 0.5 ? 2.0 * t * t : 1.0 - (-2.0 * t + 2.0) ** 2 / 2.0
        in Easing::InCubic    then t ** 3
        in Easing::OutCubic   then 1.0 - (1.0 - t) ** 3
        in Easing::InOutCubic then t < 0.5 ? 4.0 * t ** 3 : 1.0 - (-2.0 * t + 2.0) ** 3 / 2.0
        in Easing::InOutSine  then -(Math.cos(Math::PI * t) - 1.0) / 2.0
        end
      end
    end

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
    @duration : Time::Span?
    @easing : Easing
    @on_tick : Animation ->
    @on_stop : (->)?

    # Creates an animation ticking *block* every *interval*. With a *duration* it
    # is a tween (see the class docs): it runs for *duration*, easing `#value`
    # with *easing*, then stops itself. Does not start until `#start`.
    #
    # The block is handed the `Animation` itself, so it can drive its own cadence
    # (`clock.interval = …`, e.g. per-frame GIF delays), end the run early
    # (`clock.stop`), or read `clock.value` — without needing an outside reference
    # to it. A block that needs none of that can just omit the parameter.
    def initialize(@interval : Time::Span, *, duration : Time::Span? = nil,
                   easing : Easing | Symbol = Easing::Linear, &@on_tick : Animation ->)
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
      @running = true
      @completed = false

      dur = @duration
      # Phase-lock to a moving deadline instead of `sleep interval` after the
      # work: the latter makes the real period `interval + tick_work`, which
      # drifts slow and desyncs animations sharing a nominal clock.
      start_at = Time.instant
      next_at = start_at

      @fiber = Fiber.new do
        loop do
          break unless @running

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

          break unless @running

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

        @running = false
        @on_stop.try &.call
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
end
