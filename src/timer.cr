module Crysterm
  # A periodic tick source. Emits `Event::Tick` from its own fiber every
  # `interval`, so anything that wants to animate can subscribe instead of
  # spawning and pacing a loop itself.
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
  class Timer
    include EventHandler

    # Delay between ticks.
    property interval : Time::Span

    # Whether the tick fiber is currently running.
    getter? running = false

    @fiber : Fiber?

    # Creates a timer ticking every *interval*. Starts immediately unless
    # *autostart* is false (in which case call `#start` when ready).
    def initialize(@interval : Time::Span = 0.1.seconds, *, autostart : Bool = true)
      start if autostart
    end

    # Start ticking. No-op if already running.
    def start : Nil
      return if running?
      @running = true
      @fiber = Fiber.new do
        # Phase-lock to a moving deadline instead of `sleep @interval` after the
        # work: the latter makes the real period `interval + tick_work`, which
        # drifts slow and desyncs multiple timers sharing the same nominal clock.
        next_at = Time.instant
        loop do
          break unless running?
          emit Crysterm::Event::Tick
          next_at += @interval
          delay = next_at - Time.instant
          if delay > Time::Span.zero
            sleep delay
          else
            # Behind schedule (a slow tick or the process was paused): resync the
            # phase to now rather than firing a burst of catch-up ticks.
            next_at = Time.instant
          end
        end
      end.enqueue
    end

    # Stop ticking. The fiber exits on its next iteration.
    def stop : Nil
      @running = false
    end

    def toggle : Nil
      running? ? stop : start
    end

    # Convenience: subscribe *block* to run on every tick.
    def on_tick(&block : ->)
      on(Crysterm::Event::Tick) { block.call }
    end
  end
end
