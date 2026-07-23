module Crysterm
  class Widget
    # Plays a CSS `@keyframes` sequence bound via the `animation` property — a
    # looping, declarative animation (vs. `transition`, which fires once on a
    # state change). Generic across widgets; interpolates the same animatable
    # properties as transitions (`opacity`, `color`, `background-color`, `tint`)
    # across the keyframe stops, writing the resolved style each frame.

    # One resolved keyframe stop: its offset (`0..1`) and the animatable values it
    # sets (nil = not set by this stop).
    private record KFStop,
      offset : Float64,
      opacity : Float64?,
      fg : Int32?,
      bg : Int32?,
      tint_alpha : Float64?,
      tint : Int32?

    @css_animation : FrameClock?
    @css_animation_spec : ::Crysterm::Style::AnimationSpec?
    # True once a *finite* animation has run out its iterations, so it isn't
    # restarted on every subsequent render.
    @css_animation_finished = false
    # The raw `@keyframes` stops the running animation was resolved from.
    # `@css_animation_spec` alone can't detect a stylesheet swap whose
    # `animation:` declaration is unchanged but whose `@keyframes` body changed or
    # vanished: the spec is a value record and compares equal, so the old clock
    # would keep writing obsolete stops forever. A reparse allocates new stop
    # arrays, so a per-render `same?` against the current lookup catches the swap.
    @css_animation_keyframes : Array(Tuple(Float64, Hash(String, String)))?
    # Whether the one-time `Event::Hide`/`Event::Detached` clock-stop hooks have
    # been installed (lazily, on first `start_css_animation`), so they aren't
    # registered on every start.
    @css_animation_hooks_installed = false

    # Starts/keeps/stops this widget's CSS `animation` to match its current style.
    # A cheap no-op when no `animation` is declared. Called once per render.
    def ensure_css_animation : Nil
      spec = style.animation
      if spec.nil?
        stop_css_animation
      elsif @css_animation_spec != spec
        start_css_animation spec # new/changed animation
      elsif !(window?.try(&.css_keyframes(spec.name))).same?(@css_animation_keyframes)
        start_css_animation spec # same spec, but the @keyframes body was swapped
      elsif !@css_animation_finished && !(@css_animation.try(&.running?))
        start_css_animation spec # same animation, stopped unexpectedly: resume
      end
    end

    private def stop_css_animation : Nil
      return unless @css_animation || @css_animation_spec
      @css_animation.try &.stop
      @css_animation = nil
      @css_animation_spec = nil
      @css_animation_finished = false
      @css_animation_keyframes = nil
    end

    # Seconds elapsed since *start_at* (a `Time.instant` reading), driving progress
    # from real wall-clock time rather than a fixed per-tick step — `FrameClock`
    # drops catch-up ticks when behind, so an accumulator would undercount them.
    private def elapsed_since(start_at : Time::Instant) : Float64
      (Time.instant - start_at).total_seconds
    end

    private def start_css_animation(spec : ::Crysterm::Style::AnimationSpec) : Nil
      # Stop any previous clock and record the (possibly failing) new spec up
      # front — *before* the early returns below. Swapping `animation:` to a
      # missing/short `@keyframes` must still stop the old animation (otherwise
      # its `FrameClock` keeps ticking the old keyframes forever) and record the
      # new spec so `ensure_css_animation` doesn't re-attempt (and re-fail) the
      # lookup on every render.
      @css_animation.try &.stop
      @css_animation = nil
      @css_animation_spec = spec
      @css_animation_finished = false
      @css_animation_keyframes = nil

      # Stop the driving `FrameClock` when the widget is hidden or detached, or
      # its fiber keeps ticking `apply_keyframe` + `request_render` forever: a
      # hidden widget is skipped by packing layouts (its `coords` is nil, so
      # `_render` never reaches `ensure_css_animation` to notice), and a
      # detached-but-alive widget's `request_render` no-ops while the clock still
      # burns CPU. The stop leaves `@css_animation_finished` false, so the resume
      # branch in `ensure_css_animation` restarts the animation on the first
      # render after `show`/re-attach. `Event::Hide` also propagates to
      # descendants (via `emit_descendants`), covering animated children of a
      # hidden container. Installed once, on first start (mirrors
      # `Effect::Animated`'s one-time `Event::Destroy` hook).
      unless @css_animation_hooks_installed
        @css_animation_hooks_installed = true
        on(::Crysterm::Event::Hide) { @css_animation.try &.stop }
        on(::Crysterm::Event::Detached) { @css_animation.try &.stop }
      end

      scr = window? || return
      raw = scr.css_keyframes(spec.name)
      # Record the exact lookup result (even a failing one) so the per-render
      # staleness check in `ensure_css_animation` compares identities against
      # what the current stylesheet actually provides.
      @css_animation_keyframes = raw
      unless raw && raw.size >= 2
        # No usable keyframes (missing name or a single stop): leave the spec
        # recorded and mark it finished so the failed lookup isn't repeated on
        # every subsequent render (the resume branch skips a finished animation).
        @css_animation_finished = true
        return
      end
      stops = resolve_keyframes raw
      total = spec.duration.total_seconds
      total = 0.001 if total <= 0
      step = 1.0 / 30
      iters = spec.iterations
      alt = spec.alternate

      if iters == 0
        # `animation-iteration-count: 0` → zero active duration; with the default
        # fill-mode (`none`, the only mode this driver models) the element keeps
        # its base style. Mark finished (so the resume branch doesn't restart it)
        # and return before creating the FrameClock, never calling `apply_keyframe`
        # — otherwise the settle branch would stamp the final keyframe's values.
        @css_animation_finished = true
        return
      end

      # Drive progress from real wall-clock elapsed, not a fixed per-tick step:
      # dropped/late ticks are real time the animation must still count, or a
      # finite animation outruns its duration and a looping one drifts under load.
      start_at = Time.instant
      anim = FrameClock.new(step.seconds) do |clock|
        elapsed = elapsed_since(start_at)
        cycles = elapsed / total
        if iters && cycles >= iters
          # Settle on the final frame (honoring alternate parity), stop, and mark
          # finished so the next render doesn't restart it.
          frac = (alt && (iters - 1).odd?) ? 0.0 : 1.0
          # Resolve `style` per tick rather than capturing it once: a recascade
          # replaces the widget's `Style` wholesale, so a captured object would be
          # orphaned — the clock mutating a `Style` nothing renders, while the
          # animation appears frozen.
          apply_keyframe stops, style, frac
          @css_animation_finished = true
          clock.stop
        else
          apply_keyframe stops, style, spec.easing.apply(keyframe_cycle_frac(cycles, alt))
        end
        request_render
      end
      @css_animation = anim
      @css_animation_spec = spec
      anim.start
    end

    # Progress `0..1` within the current keyframe cycle at *cycles* total cycles
    # elapsed (`elapsed / duration`), honoring the alternate-direction flag *alt*.
    #
    # Uses float modulo rather than `cycles.to_i`: for `iterations: infinite`
    # `cycles` grows without bound, and `Float64#to_i` raises `OverflowError` past
    # `Int32::MAX`, killing the driving `FrameClock` fiber. `cycles % 2.0 >= 1.0`
    # tests the same odd-integer-part parity the ping-pong direction needs.
    protected def keyframe_cycle_frac(cycles : Float64, alt : Bool) : Float64
      frac = cycles % 1.0
      frac = 1.0 - frac if alt && (cycles % 2.0) >= 1.0
      frac
    end

    # Resolves each raw keyframe stop's declarations into concrete animatable
    # values by applying them onto a scratch `Style`.
    private def resolve_keyframes(raw : Array(Tuple(Float64, Hash(String, String)))) : Array(KFStop)
      raw.map do |(off, decls)|
        s = ::Crysterm::Style.new
        decls.each { |k, v| ::Crysterm::CSS::Properties.apply(s, k, v) }
        has_tint = decls.has_key?("tint")
        KFStop.new(off, s.opacity, s.fg, s.bg, (has_tint ? s.tint_alpha : nil), (has_tint ? s.tint : nil))
      end
    end

    # Writes the interpolated keyframe values at progress *p* (`0..1`) onto *st*.
    private def apply_keyframe(stops : Array(KFStop), st : ::Crysterm::Style, p : Float64) : Nil
      p = p.clamp(0.0, 1.0)
      a = stops.first
      b = stops.last
      # Plain index loop instead of `each_cons(2)`: this runs once per tick per
      # running animation, and must not allocate.
      i = 0
      while i < stops.size - 1
        if p >= stops[i].offset && p <= stops[i + 1].offset
          a, b = stops[i], stops[i + 1]
          break
        end
        i += 1
      end
      span = b.offset - a.offset
      # Clamp the interpolation fraction: when the declared stops don't span the
      # whole `0%..100%` range (CSS fills the missing boundary from the element's
      # computed value; this driver doesn't synthesize that), a `p` outside
      # `[a.offset, b.offset]` would extrapolate opacity and colors past their
      # endpoints.
      t = span > 0 ? ((p - a.offset) / span).clamp(0.0, 1.0) : 0.0

      kf_channel(opacity) { |av, bv| av + (bv - av) * t }
      kf_channel(tint_alpha) { |aa, ba| aa + (ba - aa) * t }
      # The tint *color* must be carried alongside the strength: `Style#tint?`
      # (and thus the tint overlay) is inert while `@tint` is nil regardless of
      # `tint_alpha`, so a tint-only keyframe animation is invisible without it.
      kf_channel(tint) { |ac, bc| lerp_color(ac, bc, t) }
      kf_channel(fg) { |af, bf| kf_lerp_color(af, bf, t, true) }
      kf_channel(bg) { |ab, bb| kf_lerp_color(ab, bb, t, false) }
    end

    # Expands one keyframe channel with the shared interpolation rule: both
    # segment endpoints declare the value → interpolate via the block (its two
    # parameters name the non-nil endpoints; keep them distinct per channel, or
    # the conditional reassignments union their types), exactly one declares it
    # → carry that value as a constant, neither → leave the base style value.
    # One expansion for all five channels so a future channel (or a fix to one)
    # can't regress the carry — fg/bg used to lack it, silently dropping a
    # color declared at a stop whose segment partner omitted it.
    private macro kf_channel(chan, &interp)
      if ({{interp.args[0]}} = a.{{chan.id}}) && ({{interp.args[1]}} = b.{{chan.id}})
        st.{{chan.id}} = {{interp.body}}
      elsif %v = (a.{{chan.id}} || b.{{chan.id}})
        st.{{chan.id}} = %v
      end
    end

    # Interpolates a keyframe color channel, keeping the `-1` terminal-default
    # sentinel intact: boundary fractions return the RAW endpoint (so a stop
    # declaring `transparent` really settles on the terminal default, not the
    # configured approximation), mid-frames lerp in resolved RGB space (via
    # `resolve_anim_color`, since `Colors.mix` reads `-1`'s bits as `0xFFFFFF`
    # and would wash the tween through white), and an endpoint whose default is
    # unknown snaps to the nearest raw endpoint instead of lerping.
    private def kf_lerp_color(af : Int32, bf : Int32, t : Float64, fg : Bool) : Int32
      return bf if t >= 1.0
      return af if t <= 0.0
      ra = resolve_anim_color(af, fg)
      rb = resolve_anim_color(bf, fg)
      return (t < 0.5 ? af : bf) if ra.nil? || rb.nil?
      lerp_color(ra, rb, t)
    end
  end
end
