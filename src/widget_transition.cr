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
    # state's values can be tweened *from* them. `tint_alpha` is the *effective*
    # strength (0.0 when no tint color is set — the raw field defaults to 0.5
    # even for a tint-less style) and `tint` the color it applies to.
    record TransitionFrom, fg : Int32?, bg : Int32?, opacity : Float64?, tint_alpha : Float64, tint : Int32?

    # Running per-property transition animations, so a re-triggered transition
    # replaces (rather than stacks on) the one already in flight.
    @style_transitions : Hash(Symbol, FrameClock)?

    # Snapshots the current animatable style values. Unconditional — *not* gated
    # on the OLD state declaring `transitions` — because CSS lets the destination
    # state's `transition` govern the enter animation: `Button:hover { transition:
    # ... }` must still tween on entry, which needs a `prev` snapshot the old
    # style never asked for. `TransitionFrom` is a struct, so this stays
    # allocation-free.
    protected def transition_from : TransitionFrom?
      s = style
      # `tint?` (not the raw fields) so a mid-tween retrigger eases from the
      # partial value, and a tint-less state snapshots strength 0.
      TransitionFrom.new s.fg, s.bg, s.opacity, effective_tint_strength(s), s.tint?.try(&.[0])
    end

    # The style's *effective* tint strength: its `tint_alpha` when a tint color
    # is actually set and non-transparent (via `Style#tint?`), else `0.0`. The
    # raw `tint_alpha` field defaults to 0.5 even when no tint renders, so
    # animation code must never ease from/to the raw field. Shared with
    # `Widget#tint_to`.
    protected def effective_tint_strength(style : ::Crysterm::Style) : Float64
      style.tint?.try(&.[1]) || 0.0
    end

    # Tweens each declared, changed animatable property from *prev* to the new
    # (post-state-change) style value.
    #
    # The tick blocks write through `state_style` re-resolved per tick, never a
    # `Style` captured here: a recascade replaces the widget's per-state `Style`
    # wholesale, so a captured object would be orphaned mid-tween — the clock
    # mutating a `Style` nothing renders while the visible value snaps to the
    # target. `st` is read once, up front, for the tween targets.
    def apply_style_transitions(prev : TransitionFrom) : Nil
      # Stop and clear every in-flight tween before (re)building. A state change
      # into a state whose `transition` map omits a currently-tweening property
      # must not let that tween keep running: it writes through the per-tick
      # re-resolved `state_style`, so it would interpolate toward the OLD state's
      # now-stale target and corrupt the NEW state's style, which no recascade
      # repairs for a subject-state rule. Properties the new map still declares
      # are rebuilt from `prev` below.
      @style_transitions.try { |h| h.each_value(&.stop); h.clear }
      return unless window?
      st = style
      trans = st.transitions
      return unless trans
      trans.each do |prop, spec|
        # `all` is expanded below, after the explicit per-property entries, so
        # an explicit entry can override it (per CSS).
        next if prop == "all"
        apply_transition_prop prop, spec[0], spec[1], prev, st
      end
      # `transition: all` tweens every supported property, but a concrete
      # per-property entry overrides it (per CSS), so skip any property the map
      # declares explicitly — including the `background` alias of
      # `background-color`. Expanding here rather than at parse time makes this
      # independent of declaration order.
      if all = trans["all"]?
        {"opacity", "color", "background-color", "tint"}.each do |prop|
          next if trans.has_key? prop
          next if prop == "background-color" && trans.has_key?("background")
          apply_transition_prop prop, all[0], all[1], prev, st
        end
      end
    end

    # Dispatches a single animatable property to its tween, from *prev* to the
    # new (post-state-change) *st* value.
    private def apply_transition_prop(prop : String, dur : Time::Span, easing : Easing,
                                      prev : TransitionFrom, st : ::Crysterm::Style) : Nil
      case prop
      when "opacity"
        transition_float(:opacity, prev.opacity || 1.0, st.opacity || 1.0, dur, easing) { |v| state_style.opacity = v }
      when "color"
        transition_color(:color, prev.fg, st.fg, dur, easing) { |v| state_style.fg = v }
      when "background-color", "background"
        transition_color(:bg, prev.bg, st.bg, dur, easing) { |v| state_style.bg = v }
      when "tint"
        transition_tint(prev, st, dur, easing)
      end
    end

    # Tweens the *effective* tint — color and strength via `Style#tint?` — not
    # the raw `tint_alpha` field: that field defaults to 0.5 even with no tint
    # color, and a nil-`@tint` state renders no overlay regardless of alpha, so
    # raw-field tweening made `transition: tint` a silent no-op in the standard
    # declare-tint-only-in-the-highlight-state pattern. Mirrors the two sibling
    # drivers (`tint_to`, `apply_keyframe`), which already ease the effective
    # strength and carry the color alongside it.
    private def transition_tint(prev : TransitionFrom, st : ::Crysterm::Style,
                                dur : Time::Span, easing : Easing) : Nil
      cancel_transition(:tint)
      to_t = st.tint?
      from_a = prev.tint_alpha
      to_a = to_t.try(&.[1]) || 0.0
      from_c = prev.tint
      to_c = to_t.try(&.[0])
      # No tint on either side: nothing to draw. (Also binds the single
      # declared color for the appear/disappear branch below.)
      return unless single_c = to_c || from_c
      # Nothing changes visually (same strength, and same — or only one —
      # color): snapping is correct, and a 0-length tween would only churn.
      return if from_a == to_a && (from_c == to_c || from_c.nil? || to_c.nil?)
      anim =
        if from_c && to_c
          # Cross-fade the color while easing the strength.
          cf = from_c
          ct = to_c
          start_tween(dur, easing) do |clock|
            v = clock.value
            s2 = state_style
            s2.tint = lerp_color(cf, ct, v)
            s2.tint_alpha = from_a + (to_a - from_a) * v
          end
        else
          # Appearing/disappearing tint: hold the single declared color and
          # ease the strength. A fade-out's final tick lands exactly on alpha
          # 0.0 (`FrameClock` clamps to 1.0), leaving `tint?` inert as before;
          # the residual `@tint` color is invisible at alpha 0 and is rebuilt
          # away by the next recascade (same residue `set_tint` leaves).
          color = single_c
          start_tween(dur, easing) do |clock|
            s2 = state_style
            s2.tint = color
            s2.tint_alpha = from_a + (to_a - from_a) * clock.value
          end
        end
      (@style_transitions ||= {} of Symbol => FrameClock)[:tint] = anim
      nil
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

    # Builds and starts a tween: a `FrameClock` handing *tick* the clock each
    # frame and requesting a render, with *on_done* fired only on natural
    # completion (not on an interrupting `#stop`). *store* records it *before* the
    # start, so a synchronous start (e.g. reduced motion) already sees it stored.
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

    # Resolves a color endpoint for animation math: `nil` stays `nil`; the `-1`
    # terminal-default sentinel is substituted with the configured default RGB
    # (`Colors.default_fg_rgb`/`default_bg_rgb`), or `nil` when that substitute
    # is itself unknown (`-1`); a concrete color passes through. Without this,
    # `Colors.mix` reads `-1`'s bits as `0xFFFFFF` (arithmetic shift) and the
    # tween blends through — and permanently lands on — pure white instead of
    # the terminal default (the same hazard `Colors.tint_field` guards against).
    private def resolve_anim_color(c : Int32?, fg : Bool) : Int32?
      return nil unless c
      return c unless c == -1
      d = fg ? Colors.default_fg_rgb : Colors.default_bg_rgb
      d == -1 ? nil : d
    end

    private def transition_color(key : Symbol, from : Int32?, to : Int32?,
                                 dur : Time::Span, easing : Easing, &set : Int32 ->) : Nil
      # Cancel first, even on the no-op early returns (nil target or from == to):
      # otherwise a prior tween keeps writing toward its old (now stale) target.
      cancel_transition(key)
      return if !(from && to) || from == to
      f, t = from || 0, to || 0
      # Tween in resolved RGB space, so a `-1` terminal-default endpoint eases
      # from/toward the configured default rather than white. Snap straight to
      # the raw target when an endpoint is unresolvable (unknown terminal
      # default) or resolution collapses the change to a no-op.
      rf = resolve_anim_color(f, key == :color)
      rt = resolve_anim_color(t, key == :color)
      if rf.nil? || rt.nil? || rf == rt
        set.call(t)
        return
      end
      mf, mt = rf, rt
      # `on_done` restores the exact raw target on natural completion — for a
      # `-1` target the final mix product would otherwise permanently replace
      # the state's computed sentinel with the substitute RGB.
      anim = start_tween(dur, easing, on_done: -> { set.call(t); nil }) do |clock|
        # Per-channel `from + (to-from)*t` via the shared `Colors.mix`, whose
        # first arg is weighted by `alpha`: weight-of-`t` (the target) = the
        # tween value, so `mix(t, f, clock.value)`.
        set.call(Colors.mix(mt, mf, clock.value))
      end
      (@style_transitions ||= {} of Symbol => FrameClock)[key] = anim
      nil
    end

    # Per-channel linear interpolation `from + (to-from)*t` between two
    # `0xRRGGBB` colors, via the shared `Colors.mix` (whose first arg is
    # weighted by `alpha`, so weight-of-`to` = `t`).
    private def lerp_color(from : Int32, to : Int32, t : Float64) : Int32
      Colors.mix(to, from, t)
    end
  end
end
