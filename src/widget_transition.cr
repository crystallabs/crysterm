module Crysterm
  class Widget
    # Declarative CSS `transition` support: when an animatable style property
    # changes (typically on a `:hover`/`:focus`/`:selected` state change), tween
    # it over its declared duration instead of snapping to the new value.
    #
    # Built on the `FrameClock` driver and generic across widgets. The tween
    # writes the current per-state style each frame, so the renderer reads the
    # in-between value and lands exactly on the target.

    # Snapshot of the animatable values *before* a state change, so the new
    # state's values can be tweened *from* them.
    record TransitionFrom, fg : Int32?, bg : Int32?, alpha : Float64?, tint_alpha : Float64

    # Running per-property transition animations, so a re-triggered transition
    # replaces (rather than stacks on) the one already in flight.
    @style_transitions : Hash(Symbol, FrameClock)?

    # Snapshots the current animatable style values, but only when a `transition`
    # is declared, so the common no-transition path stays free.
    def transition_from : TransitionFrom?
      s = style
      return nil if s.transitions.nil?
      TransitionFrom.new s.fg, s.bg, s.alpha, s.tint_alpha
    end

    # Tweens each declared, changed animatable property from *prev* to the new
    # (post-state-change) style value. Called from `Mixin::Style#state=`.
    #
    # The tick blocks write through `state_style` re-resolved per tick, never a
    # `Style` captured here: a recascade replaces the widget's per-state `Style`
    # wholesale (`css_base_styles.deep_dup`), so a captured object would be
    # orphaned mid-tween — the clock mutating a `Style` nothing renders while
    # the visible value snaps to the target (the exact hazard the keyframe
    # driver documents and avoids in `widget_animation.cr`). `st` is only read
    # here, up front, for the tween targets — the new state's computed values.
    def apply_style_transitions(prev : TransitionFrom) : Nil
      return unless window?
      st = style
      trans = st.transitions
      return unless trans
      trans.each do |prop, spec|
        dur, easing = spec
        case prop
        when "opacity"
          transition_float(:opacity, prev.alpha || 1.0, st.alpha || 1.0, dur, easing) { |v| state_style.alpha = v }
        when "color"
          transition_color(:color, prev.fg, st.fg, dur, easing) { |v| state_style.fg = v }
        when "background-color", "background"
          transition_color(:bg, prev.bg, st.bg, dur, easing) { |v| state_style.bg = v }
        when "tint"
          transition_float(:tint, prev.tint_alpha, st.tint_alpha, dur, easing) { |v| state_style.tint_alpha = v }
        end
      end
    end

    # Whether any declarative CSS `transition` is currently tweening on this
    # widget. Drives `Window#animating?`, polled by capture/test harnesses to
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

    # Builds a tween: cancels whatever is already running (via *cancel* — e.g.
    # `#cancel_transition`, or clearing a fade/tint ivar), skips creating a new
    # `FrameClock` when *skip* is true (having still cancelled), otherwise
    # builds one that hands *tick* the clock each frame and requests a render,
    # wires *on_done* to fire only on natural completion (not on an
    # interrupting `#stop`), records it via *store* — *before* starting it, so
    # a synchronous start (e.g. reduced motion) already sees it stored — and
    # starts it. Returns the `FrameClock`, or `nil` when skipped.
    #
    # Shared by `#transition_float`/`#transition_color` below (keyed storage,
    # several concurrent transitions per widget) and the fade/tint builders in
    # `widget_fade.cr` (a single ivar each) — they differ only in how they
    # cancel/store the tween, so those steps are passed in as procs.
    private def start_tween(duration : Time::Span, easing : Easing | Symbol,
                            fps : Int32 = 30, on_done : Proc(Nil)? = nil, store : Proc(FrameClock, Nil)? = nil,
                            &tick : FrameClock ->) : FrameClock
      anim = FrameClock.new((1.0 / fps).seconds, duration: duration, easing: easing) do |clock|
        tick.call clock
        request_render
      end
      if od = on_done
        anim.on_stop { od.call if anim.completed? }
      end
      store.try &.call(anim)
      anim.start
      anim
    end

    private def transition_float(key : Symbol, from : Float64, to : Float64,
                                 dur : Time::Span, easing : Easing, &set : Float64 ->) : Nil
      # Cancel first, even on the no-op early return: a state change to the
      # current value must still stop a prior tween, or it keeps writing toward
      # its old (now stale) target.
      cancel_transition(key)
      return if (from - to).abs < 1e-6
      anim = start_tween(dur, easing) do |clock|
        set.call(from + (to - from) * clock.value)
      end
      (@style_transitions ||= {} of Symbol => FrameClock)[key] = anim
      nil
    end

    private def transition_color(key : Symbol, from : Int32?, to : Int32?,
                                 dur : Time::Span, easing : Easing, &set : Int32 ->) : Nil
      # Cancel first, even on the no-op early returns (nil target or from == to):
      # otherwise a prior tween keeps writing toward its old (now stale) target.
      cancel_transition(key)
      return if !(from && to) || from == to
      f, t = from || 0, to || 0
      anim = start_tween(dur, easing) do |clock|
        # Per-channel `from + (to-from)*t` via the shared `Colors.mix`, whose
        # first arg is weighted by `alpha`: weight-of-`t` (the target) = the
        # tween value, so `mix(t, f, clock.value)`.
        set.call(Colors.mix(t, f, clock.value))
      end
      (@style_transitions ||= {} of Symbol => FrameClock)[key] = anim
      nil
    end

    # Per-channel linear interpolation `from + (to-from)*t` between two
    # `0xRRGGBB` colors, via the shared `Colors.mix` (whose first arg is
    # weighted by `alpha`, so weight-of-`to` = `t`). Used by `#animate` in
    # `widget_animation.cr`.
    private def lerp_color(from : Int32, to : Int32, t : Float64) : Int32
      Colors.mix(to, from, t)
    end
  end
end
