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

    # The underlying frame clock (phase-locking, lifecycle); created on `#start`.
    @animation : Animation?

    # Creates a timer ticking every *interval*. Starts immediately unless
    # *autostart* is false (in which case call `#start` when ready).
    def initialize(@interval : Time::Span = 0.1.seconds, *, autostart : Bool = true)
      start if autostart
    end

    # Whether the tick fiber is currently running.
    def running? : Bool
      @animation.try(&.running?) || false
    end

    # Start ticking. No-op if already running. The phase-locked loop (which keeps
    # multiple timers sharing a nominal clock in sync) lives in `Animation`.
    def start : Nil
      return if running?
      @animation = Animation.new(@interval) { emit Crysterm::Event::Tick }
      @animation.try &.start
    end

    # Stop ticking. The fiber exits on its next iteration.
    def stop : Nil
      @animation.try &.stop
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
