require "./mixin/visibility_paused_clock"

module Crysterm
  class Widget
    # Shared pause-while-invisible / resume-when-visible core for the
    # self-driven `FrameClock`s on a widget (`#pulse` below,
    # `Effect::Animated`).
    include ::Crysterm::Mixin::VisibilityPausedClock

    # Opacity animation — fades and pulses — built on the tween side of
    # `FrameClock`. Each frame eases `style.opacity` and requests a render; the
    # per-cell alpha blend turns that into translucency over whatever is behind
    # the widget.
    #
    # ```
    # box.fade_in                       # 0 → opaque over the default duration
    # box.fade_out(0.5.seconds) { ... } # → transparent, then a callback (e.g. destroy)
    # box.fade_to 0.4                   # settle at 40% opacity
    # box.pulse                         # breathe between 0.3 and 1.0 until stopped
    # box.stop_fade                     # cancel whatever is running
    # ```

    # The running fade/pulse, if any. A new one cancels it first, so two
    # animations never fight over `style.opacity`.
    @fade : FrameClock?

    # The `FrameClock` created by the *current* `#pulse` call, if any —
    # distinct from `@fade` so the Hide/Detached/Show/Attached hooks below can
    # tell "the running fade is this pulse" (safe to pause/resume) from "the
    # running fade is a `#fade_to`/`#fade_in`/`#fade_out` tween that has since
    # superseded the pulse" (must not be touched: pausing an interrupted tween
    # and resuming it later would re-fire its `on_done`, e.g. `#fade_out`'s
    # `#hide` + callback, unexpectedly).
    @pulse_clock : FrameClock?

    # Set by `#pause_pulse` when `@pulse_clock` is stopped for visibility (as
    # opposed to an explicit `#stop_fade`), so the Show/Attached hook knows to
    # resume it — and so an explicit `#stop_fade` issued while hidden isn't
    # silently undone by the next show.
    @pulse_paused = false

    # Whether the one-time `Event::Hide`/`Event::Detached` pause and
    # `Event::Show`/`Event::Attached` resume hooks have been installed
    # (lazily, on first `#pulse`), so they aren't registered on every call.
    @fade_hooks_installed = false

    # Default fade length, shared by `#fade_in`/`#fade_out`/`#fade_to`.
    FADE_DURATION = 0.3.seconds

    # Frames per second the opacity tweens sample at (their `FrameClock#interval`).
    FADE_FPS = 30

    # Animates opacity to *target* (`0.0` transparent .. `1.0` opaque) over
    # *duration*, easing with *easing*. Cancels any fade already running. When the
    # tween finishes naturally, *on_done* runs (not on an interrupting cancel).
    # Returns the `FrameClock` so the caller can `#stop` it directly.
    def fade_to(target : Float64, duration : Time::Span = FADE_DURATION,
                easing : Easing | Symbol = :in_out_sine,
                fps : Int32 = FADE_FPS, &on_done : ->) : FrameClock
      from = (style.opacity? || 1.0).to_f
      @fade.try &.stop
      start_tween(duration, easing, fps: fps, on_done: on_done,
        store: ->(anim : FrameClock) { @fade = anim }) do |clock|
        set_opacity from + (target - from) * clock.value
      end
    end

    # :ditto: (no completion callback).
    def fade_to(target : Float64, duration : Time::Span = FADE_DURATION,
                easing : Easing | Symbol = :in_out_sine,
                fps : Int32 = FADE_FPS) : FrameClock
      fade_to(target, duration, easing, fps) { }
    end

    # Makes the widget visible and fades it from fully transparent to opaque,
    # then clears `style.opacity` (no per-cell blend cost once shown). *on_done*
    # runs after it lands.
    def fade_in(duration : Time::Span = FADE_DURATION,
                easing : Easing | Symbol = :in_out_sine,
                fps : Int32 = FADE_FPS, &on_done : ->) : FrameClock
      show
      set_opacity 0.0
      request_render
      fade_to(1.0, duration, easing, fps) do
        set_opacity nil # fully opaque ⇒ no blend; drop the opacity entirely
        on_done.call
      end
    end

    # :ditto: (no completion callback).
    def fade_in(duration : Time::Span = FADE_DURATION,
                easing : Easing | Symbol = :in_out_sine,
                fps : Int32 = FADE_FPS) : FrameClock
      fade_in(duration, easing, fps) { }
    end

    # Fades the widget to fully transparent, then `#hide`s it (so it stops
    # rendering and releases focus). *on_done* runs after it is hidden.
    def fade_out(duration : Time::Span = FADE_DURATION,
                 easing : Easing | Symbol = :in_out_sine,
                 fps : Int32 = FADE_FPS, &on_done : ->) : FrameClock
      fade_to(0.0, duration, easing, fps) do
        hide
        # Clear the residual opacity == 0.0, or a later plain `#show` paints nothing.
        set_opacity nil
        on_done.call
      end
    end

    # :ditto: (no completion callback).
    def fade_out(duration : Time::Span = FADE_DURATION,
                 easing : Easing | Symbol = :in_out_sine,
                 fps : Int32 = FADE_FPS) : FrameClock
      fade_out(duration, easing, fps) { }
    end

    # Continuously breathes opacity between *min* and *max* (a sine in/out each
    # way), forever, until `#stop_fade`. Cancels any fade already running. One
    # full cycle (min → max → min) takes `2 * period`.
    def pulse(min : Float64 = 0.3, max : Float64 = 1.0,
              period : Time::Span = 0.8.seconds, fps : Int32 = FADE_FPS) : FrameClock
      @fade.try &.stop
      @pulse_paused = false
      # Stop the ticker when the widget is hidden or detached, or the fiber
      # keeps ticking `set_opacity` + `request_render` forever on a widget
      # that is never painted — mirrors the CSS-animation/Effect::Animated
      # fix. The pause leaves `@pulse_paused` set, so the Show/Attached hook
      # resumes it on the first render after `show`/re-attach. Installed
      # once, on first `#pulse`.
      unless @fade_hooks_installed
        @fade_hooks_installed = true
        on(::Crysterm::Event::Hide) { pause_pulse }
        on(::Crysterm::Event::Detached) { pause_pulse }
        on(::Crysterm::Event::Show) { resume_pulse }
        on(::Crysterm::Event::Attached) { resume_pulse }
      end
      interval = (1.0 / fps).seconds
      # A ticker (not a tween): maps elapsed time through a triangle + sine so
      # the value eases at both ends and runs until stopped.
      half = period.total_seconds
      # `period` is unvalidated public API: a zero/negative span makes `half == 0`,
      # and the first tick's `elapsed % (2.0 * half)` raises DivisionByZeroError,
      # killing the ticker fiber.
      half = 0.001 if half <= 0.0
      # Drive the phase from real wall-clock elapsed, not a fixed per-tick step:
      # `FrameClock` drops catch-up ticks when behind, so an accumulator would
      # undercount every late tick and stretch the breathe cadence under load.
      start_at = Time.instant
      anim = FrameClock.new(interval) do |_clock|
        elapsed = FrameClock.elapsed_since(start_at)
        # Triangle phase 0→1→0 over `2*half`, eased by sine for a soft turnaround.
        phase = (elapsed % (2.0 * half)) / half  # 0..2
        tri = phase <= 1.0 ? phase : 2.0 - phase # 0..1..0
        eased = Easing::InOutSine.apply(tri)
        set_opacity min + (max - min) * eased
        request_render
      end
      @fade = anim
      @pulse_clock = anim
      anim.start
    end

    # Stops any running fade/pulse, leaving `style.opacity` at its current
    # value. Also clears `@pulse_paused`, so an explicit `#stop_fade` issued
    # while hidden/detached sticks — the next `Event::Show`/`Event::Attached`
    # must not silently resume a pulse the caller deliberately ended.
    def stop_fade : Nil
      @pulse_paused = false
      @fade.try &.stop
      @fade = nil
    end

    # Stops `@pulse_clock` for visibility (called from the one-time
    # `Event::Hide`/`Event::Detached` hooks installed by `#pulse`), unlike a
    # plain `#stop_fade` this leaves `@pulse_paused` set so it resumes
    # automatically once the widget is visible again (see
    # `Mixin::VisibilityPausedClock`). Guarded on `@fade` still being this
    # exact pulse clock — a `#fade_to`/`#fade_in`/`#fade_out` call made after
    # `#pulse` replaces `@fade` with its own tween, which must not be
    # paused/resumed here (see `@pulse_clock`'s doc).
    private def pause_pulse : Nil
      clock = @pulse_clock
      @pulse_paused = true if visibility_pause(clock, eligible: @fade.same?(clock))
    end

    # Resumes a pulse previously stopped by `#pause_pulse` (called from the
    # one-time `Event::Show`/`Event::Attached` hooks), subject to the same
    # this-is-still-our-clock guard as `#pause_pulse` and to the visibility
    # gate in `Mixin::VisibilityPausedClock#visibility_resume?`. Resumes the
    # *same* `FrameClock` (rather than rebuilding one via `#pulse`) — its tick
    # block computes opacity from wall-clock elapsed since a captured
    # `start_at`, so restarting it stays phase-continuous instead of jumping
    # back to the start of the breathe cycle.
    private def resume_pulse : Nil
      clock = @pulse_clock
      return unless clock && @fade.same?(clock)
      return unless visibility_resume?(@pulse_paused)
      @pulse_paused = false
      clock.start
    end

    # The running tint animation, if any. Separate from `@fade` so a widget can
    # fade and tint at the same time.
    @tint_anim : FrameClock?

    # Animates a color overlay: tints the widget toward *color*, ramping overlay
    # strength to *target* (`0.0`..`1.0`) over *duration*. Eases from the current
    # strength if a tint is already running, else from 0. Cancels any tint
    # already running. *on_done* fires on natural completion only.
    def tint_to(color, target : Float64 = 0.5, duration : Time::Span = FADE_DURATION,
                easing : Easing | Symbol = :in_out_sine,
                fps : Int32 = FADE_FPS, &on_done : ->) : FrameClock
      from = effective_tint_strength(style) # current strength, or 0 if no tint yet
      @tint_anim.try &.stop
      start_tween(duration, easing, fps: fps, on_done: on_done,
        store: ->(anim : FrameClock) { @tint_anim = anim }) do |clock|
        set_tint color, from + (target - from) * clock.value
      end
    end

    # :ditto: (no completion callback).
    def tint_to(color, target : Float64 = 0.5, duration : Time::Span = FADE_DURATION,
                easing : Easing | Symbol = :in_out_sine,
                fps : Int32 = FADE_FPS) : FrameClock
      tint_to(color, target, duration, easing, fps) { }
    end

    # Stops any running tint animation, leaving `style.tint`/`tint_alpha` as-is.
    def stop_tint : Nil
      @tint_anim.try &.stop
      @tint_anim = nil
    end

    # Sets `style.opacity`, and — when CSS has taken over styling — persists it onto
    # the inline `@style` so the next cascade doesn't discard it, like
    # `#set_visible`.
    private def set_opacity(value : Float64?) : Nil
      # Write the raw backing style (`#state_style`), not `#style`: at the
      # unstyled floor, `#style` returns a transient reverse-video `#dup` for small
      # focused/selected controls (`Button`, `CheckBox`, `RadioButton`), so a write
      # through it would be discarded.
      state_style.opacity = value
      persist_inline_style(&.opacity=(value))
      # The frame-memoized `#style` may hold a detached floor-highlight `dup`
      # of the state style — drop it so the new opacity is visible immediately.
      invalidate_frame_style
    end

    # Sets `style.tint`/`tint_alpha` (CSS-safely, like `#set_opacity`).
    private def set_tint(color, alpha : Float64) : Nil
      state_style.tint = color
      state_style.tint_alpha = alpha
      persist_inline_style do |s|
        s.tint = color
        s.tint_alpha = alpha
      end
      # See `#set_opacity`.
      invalidate_frame_style
    end
  end
end
