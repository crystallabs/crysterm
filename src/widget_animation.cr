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
      alpha : Float64?,
      fg : Int32?,
      bg : Int32?,
      tint_alpha : Float64?

    @css_animation : FrameClock?
    @css_animation_spec : ::Crysterm::Style::AnimationSpec?
    # True once a *finite* animation has run out its iterations, so it isn't
    # restarted on every subsequent render.
    @css_animation_finished = false

    # Starts/keeps/stops this widget's CSS `animation` to match its current style.
    # A cheap no-op when no `animation` is declared. Called once per render.
    def ensure_css_animation : Nil
      spec = style.animation
      if spec.nil?
        stop_css_animation
      elsif @css_animation_spec != spec
        start_css_animation spec # new/changed animation
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
    end

    private def start_css_animation(spec : ::Crysterm::Style::AnimationSpec) : Nil
      scr = window? || return
      raw = scr.css_keyframes(spec.name)
      return unless raw && raw.size >= 2
      stops = resolve_keyframes raw
      st = style
      total = spec.duration.total_seconds
      total = 0.001 if total <= 0
      step = 1.0 / 30
      elapsed = 0.0
      iters = spec.iterations
      alt = spec.alternate

      @css_animation.try &.stop
      @css_animation_finished = false
      anim = FrameClock.new(step.seconds) do |clock|
        elapsed += step
        cycles = elapsed / total
        if iters && cycles >= iters
          # Settle on the final frame (honoring alternate parity), stop, and mark
          # finished so the next render doesn't restart it.
          frac = (alt && (iters - 1).odd?) ? 0.0 : 1.0
          apply_keyframe stops, st, frac
          @css_animation_finished = true
          clock.stop
        else
          n = cycles.to_i
          frac = cycles - n
          frac = 1.0 - frac if alt && n.odd?
          apply_keyframe stops, st, spec.easing.apply(frac)
        end
        request_render
      end
      @css_animation = anim
      @css_animation_spec = spec
      anim.start
    end

    # Resolves each raw keyframe stop's declarations into concrete animatable
    # values by applying them onto a scratch `Style`.
    private def resolve_keyframes(raw : Array(Tuple(Float64, Hash(String, String)))) : Array(KFStop)
      raw.map do |(off, decls)|
        s = ::Crysterm::Style.new
        decls.each { |k, v| ::Crysterm::CSS::Properties.apply(s, k, v) }
        KFStop.new(off, s.alpha, s.fg, s.bg, (decls.has_key?("tint") ? s.tint_alpha : nil))
      end
    end

    # Writes the interpolated keyframe values at progress *p* (`0..1`) onto *st*.
    private def apply_keyframe(stops : Array(KFStop), st : ::Crysterm::Style, p : Float64) : Nil
      p = p.clamp(0.0, 1.0)
      a = stops.first
      b = stops.last
      # Plain index loop instead of `each_cons(2)` to avoid per-call allocation;
      # runs once per tick (~30fps) per running animation.
      i = 0
      while i < stops.size - 1
        if p >= stops[i].offset && p <= stops[i + 1].offset
          a, b = stops[i], stops[i + 1]
          break
        end
        i += 1
      end
      span = b.offset - a.offset
      t = span > 0 ? (p - a.offset) / span : 0.0

      if (av = a.alpha) && (bv = b.alpha)
        st.alpha = av + (bv - av) * t
      elsif v = (a.alpha || b.alpha)
        st.alpha = v
      end
      if (av = a.tint_alpha) && (bv = b.tint_alpha)
        st.tint_alpha = av + (bv - av) * t
      end
      if (af = a.fg) && (bf = b.fg)
        st.fg = lerp_color(af, bf, t)
      end
      if (ab = a.bg) && (bb = b.bg)
        st.bg = lerp_color(ab, bb, t)
      end
    end
  end
end
