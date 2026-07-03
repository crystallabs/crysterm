module Crysterm
  class Widget
    # Opacity animation — fades and pulses — built on the tween side of
    # `FrameClock`. Each frame eases `style.alpha` and requests a render; the
    # per-cell alpha blend (`Colors.blend`, see `widget_rendering`) turns that
    # into translucency over whatever is behind the widget.
    #
    # ```
    # box.fade_in                       # 0 → opaque over the default duration
    # box.fade_out(0.5.seconds) { ... } # → transparent, then a callback (e.g. destroy)
    # box.fade_to 0.4                   # settle at 40% opacity
    # box.pulse                         # breathe between 0.3 and 1.0 until stopped
    # box.stop_fade                     # cancel whatever is running
    # ```

    # The running fade/pulse, if any. A new one cancels it first, so two
    # animations never fight over `style.alpha`.
    @fade : FrameClock?

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
      @fade.try &.stop
      from = (style.alpha? || 1.0).to_f
      anim = build_value_tween(from, target, duration, easing, fps, on_done) { |v| set_alpha v }
      @fade = anim
      anim.start
    end

    # Builds (but does not start) a tween that eases a scalar from *from* to
    # *target* over *duration*/*easing*, handing each interpolated value to
    # *apply* and requesting a render per frame. *on_done* fires only on natural
    # completion (not on an interrupting `#stop`). Shared by `#fade_to` and
    # `#tint_to`; the caller stops its previous tween and records the returned
    # one *before* starting it, so a synchronous start (reduced motion) already
    # sees it stored.
    private def build_value_tween(from : Float64, target : Float64, duration : Time::Span,
                                  easing : Easing | Symbol, fps : Int32,
                                  on_done : ->, &apply : Float64 ->) : FrameClock
      interval = (1.0 / fps).seconds
      anim = FrameClock.new(interval, duration: duration, easing: easing) do |clock|
        apply.call from + (target - from) * clock.value
        request_render
      end
      # `completed?` distinguishes a natural finish from an interrupting `#stop`;
      # checked on the captured `anim`, not the caller's ivar (which a
      # superseding animation may have already reassigned).
      anim.on_stop { on_done.call if anim.completed? }
      anim
    end

    # :ditto: (no completion callback).
    def fade_to(target : Float64, duration : Time::Span = FADE_DURATION,
                easing : Easing | Symbol = :in_out_sine,
                fps : Int32 = FADE_FPS) : FrameClock
      fade_to(target, duration, easing, fps) { }
    end

    # Makes the widget visible and fades it from fully transparent to opaque,
    # then clears `style.alpha` (no per-cell blend cost once shown). *on_done*
    # runs after it lands.
    def fade_in(duration : Time::Span = FADE_DURATION,
                easing : Easing | Symbol = :in_out_sine,
                fps : Int32 = FADE_FPS, &on_done : ->) : FrameClock
      show
      set_alpha 0.0
      request_render
      fade_to(1.0, duration, easing, fps) do
        set_alpha nil # fully opaque ⇒ no blend; drop the alpha entirely
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
        # Clear the residual alpha == 0.0 (mirrors `fade_in`'s `set_alpha nil`):
        # otherwise a later plain `#show` would paint nothing.
        set_alpha nil
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
      interval = (1.0 / fps).seconds
      # A ticker (not a tween): maps elapsed time through a triangle + sine so
      # the value eases at both ends and runs until stopped.
      half = period.total_seconds
      # Drive the phase from real wall-clock elapsed (like the keyframe/tween
      # path), not a fixed per-tick step: `FrameClock` drops catch-up ticks when
      # behind, so a fixed accumulator undercounts every dropped/late tick and the
      # breathe cadence stretches slow under CPU load / GC pauses.
      start_at = Time.instant
      anim = FrameClock.new(interval) do |_clock|
        elapsed = (Time.instant - start_at).total_seconds
        # Triangle phase 0→1→0 over `2*half`, eased by sine for a soft turnaround.
        phase = (elapsed % (2.0 * half)) / half  # 0..2
        tri = phase <= 1.0 ? phase : 2.0 - phase # 0..1..0
        eased = Easing::InOutSine.apply(tri)
        set_alpha min + (max - min) * eased
        request_render
      end
      @fade = anim
      anim.start
    end

    # Stops any running fade/pulse, leaving `style.alpha` at its current value.
    def stop_fade : Nil
      @fade.try &.stop
      @fade = nil
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
      @tint_anim.try &.stop
      from = style.tint?.try(&.[1]) || 0.0 # current strength, or 0 if no tint yet
      anim = build_value_tween(from, target, duration, easing, fps, on_done) { |v| set_tint color, v }
      @tint_anim = anim
      anim.start
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

    # Sets `style.alpha`, and — when CSS has taken over styling — persists it
    # onto the inline `@style` so the next cascade doesn't discard it. Mirrors
    # `#set_visible` (see `widget_visibility`).
    private def set_alpha(value : Float64?) : Nil
      # Write the raw backing style (`#state_style`), not `#style`: at the
      # unstyled floor, `#style` returns a transient reverse-video `#dup` for
      # small focused/selected controls (`floor_focus_reverse?` — `Button`,
      # `CheckBox`, `RadioButton`), so a write through it would be discarded
      # (same trap `#set_visible` avoids).
      self.state_style.alpha = value
      persist_inline_style(&.alpha=(value))
      # The frame-memoized `#style` may hold a detached floor-highlight `dup`
      # of the state style — drop it so the new alpha is visible immediately.
      invalidate_frame_style
    end

    # Sets `style.tint`/`tint_alpha` (CSS-safely, like `#set_alpha`).
    private def set_tint(color, alpha : Float64) : Nil
      self.state_style.tint = color
      self.state_style.tint_alpha = alpha
      persist_inline_style do |s|
        s.tint = color
        s.tint_alpha = alpha
      end
      # See `#set_alpha`.
      invalidate_frame_style
    end
  end
end
