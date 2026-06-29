module Crysterm
  class Widget
    # Declarative CSS `transition` support: when an animatable style property
    # changes (typically on a `:hover`/`:focus`/`:selected` state change), tween
    # it in over its declared duration instead of snapping to the new value.
    #
    # Built on the `Animation` driver and entirely generic — any widget that
    # declares a `transition` in CSS gets it, with no widget-specific code. The
    # tween writes the *current* per-state style each frame, so the renderer reads
    # the in-between value; it lands exactly on the target.

    # Snapshot of the animatable values *before* a state change, so the new
    # state's values can be tweened *from* them.
    record TransitionFrom, fg : Int32?, bg : Int32?, alpha : Float64?, tint_alpha : Float64

    # Running per-property transition animations, so a re-triggered transition
    # replaces (rather than stacks on) the one already in flight.
    @style_transitions : Hash(Symbol, Animation)?

    # Snapshots the current animatable style values — but only when a `transition`
    # is actually declared, so the common no-transition path stays free.
    def transition_from : TransitionFrom?
      s = style
      return nil if s.transitions.nil?
      TransitionFrom.new s.fg, s.bg, s.alpha, s.tint_alpha
    end

    # Tweens each declared, changed animatable property from *prev* to the new
    # (post-state-change) style value. Called from `Mixin::Style#state=`.
    def apply_style_transitions(prev : TransitionFrom) : Nil
      return unless window?
      st = style
      trans = st.transitions
      return unless trans
      trans.each do |prop, spec|
        dur, easing = spec
        case prop
        when "opacity"
          transition_float(:opacity, prev.alpha || 1.0, st.alpha || 1.0, dur, easing) { |v| st.alpha = v }
        when "color"
          transition_color(:color, prev.fg, st.fg, dur, easing) { |v| st.fg = v }
        when "background-color", "background"
          transition_color(:bg, prev.bg, st.bg, dur, easing) { |v| st.bg = v }
        when "tint"
          transition_float(:tint, prev.tint_alpha, st.tint_alpha, dur, easing) { |v| st.tint_alpha = v }
        end
      end
    end

    # Whether any declarative CSS `transition` is currently tweening on this
    # widget. Drives `Window#animating?`, which capture/test harnesses poll to
    # wait for a state change to settle before snapshotting.
    def transition_running? : Bool
      if h = @style_transitions
        h.each_value.any? &.running?
      else
        false
      end
    end

    # Stops any running transition for *key* (so a new one replaces it).
    private def cancel_transition(key : Symbol) : Nil
      @style_transitions.try { |h| h[key]?.try(&.stop); h.delete key }
    end

    private def transition_float(key : Symbol, from : Float64, to : Float64,
                                 dur : Time::Span, easing : Animation::Easing, &set : Float64 ->) : Nil
      return if (from - to).abs < 1e-6
      cancel_transition key
      anim = Animation.new((1.0 / 30).seconds, duration: dur, easing: easing) do |clock|
        set.call(from + (to - from) * clock.value)
        request_render
      end
      (@style_transitions ||= {} of Symbol => Animation)[key] = anim
      anim.start
    end

    private def transition_color(key : Symbol, from : Int32?, to : Int32?,
                                 dur : Time::Span, easing : Animation::Easing, &set : Int32 ->) : Nil
      return unless from && to
      return if from == to
      f, t = from, to
      cancel_transition key
      anim = Animation.new((1.0 / 30).seconds, duration: dur, easing: easing) do |clock|
        set.call(lerp_color(f, t, clock.value))
        request_render
      end
      (@style_transitions ||= {} of Symbol => Animation)[key] = anim
      anim.start
    end

    # Per-channel linear interpolation between two `0xRRGGBB` colors.
    private def lerp_color(from : Int32, to : Int32, t : Float64) : Int32
      fr = (from >> 16) & 0xff; fg = (from >> 8) & 0xff; fb = from & 0xff
      tr = (to >> 16) & 0xff; tg = (to >> 8) & 0xff; tb = to & 0xff
      r = (fr + (tr - fr) * t).round.to_i.clamp(0, 255)
      g = (fg + (tg - fg) * t).round.to_i.clamp(0, 255)
      b = (fb + (tb - fb) * t).round.to_i.clamp(0, 255)
      (r << 16) | (g << 8) | b
    end
  end
end
