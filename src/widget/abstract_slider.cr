require "./input"
require "../mixin/ranged_value"

module Crysterm
  class Widget
    # Abstract base for the slider family, modeled after Qt's `QAbstractSlider`.
    #
    # `Slider`, `ScrollBar` and `Dial` derive this directly as siblings (like
    # Qt's `QSlider`/`QScrollBar`/`QDial`). Holds the shared bounded-integer
    # value/range behavior (`#minimum`/`#maximum`/`#value`/`#step`/`#page_step`/
    # `#wrap?`, `#increment`/`#decrement`, `Event::ValueChange`) via
    # `Mixin::RangedValue`, included once here for all subclasses.
    #
    # `ProgressBar` does *not* derive this: Qt's `QProgressBar` is a plain
    # `QWidget`, not a `QAbstractSlider`, so it keeps its own range.
    abstract class AbstractSlider < Input
      include Mixin::RangedValue(Int32)

      # A slider/dial/scrollbar draws a fixed-size track/knob/trough; it should
      # not shrink to its (empty) content the way an `Input` does by default.
      @resizable = false

      # Amount Page Up/Down move the value by (Qt `pageStep`); required by
      # `Mixin::RangedValue#ranged_step_key`. `Slider`/`Dial` inherit this;
      # `ScrollBar` overrides it (default 1 + a change-guarded setter that
      # resyncs the thumb).
      property page_step : Int32 = 10

      # `Slider`/`Dial` indicate focus via reverse-video at the unstyled floor
      # (see `Mixin::Style#floor_focus_reverse?`), same as the button family.
      def floor_focus_reverse? : Bool
        true
      end

      # Whether `#on_keypress`'s Up/Down (and Page/Home/End) stepping runs
      # inverted (`Mixin::RangedValue#ranged_step_key`'s *invert*). `ScrollBar`
      # overrides this to `true` (Down moves toward the end, like a real
      # scrollbar); `Slider`/`Dial` keep the non-inverted default.
      protected def step_key_inverted? : Bool
        false
      end

      # Arrow/Page/Home/End stepping, shared by `Slider`/`Dial`/`ScrollBar` via
      # `Mixin::RangedValue#ranged_step_key`; only the invert direction differs
      # (see `#step_key_inverted?`).
      def on_keypress(e)
        ranged_step_key e, invert: step_key_inverted?
      end

      # `@value` stamp for the per-value string caches in `Slider`/`Dial`
      # (`#value_text`). Held here so the staleness logic is single-sourced.
      @value_text_for : Int32?

      # Returns `true` — and advances the stamp — when `@value` has changed since
      # the last call, signalling a subclass to rebuild its cached value
      # string(s); `false` when the cache is still current. The first call is
      # always stale (the stamp starts `nil`), so subclasses can seed their string
      # ivars with `""` rather than a nilable.
      private def value_text_stale? : Bool
        return false if @value_text_for == @value
        @value_text_for = @value
        true
      end

      # Value at a main-axis offset *pos* cells from the low-value end of a
      # *span*-cell track: `#minimum + round(pos/span · value_span)` — the
      # pointer→value mapping shared by `Slider` and `ScrollBar`. *pos* is *not*
      # clamped here: the two reconcile their long-standing difference at the
      # call site — `ScrollBar` pre-clamps *pos* to `0..span` (it sizes a thumb
      # and must not read past the ends), while `Slider` passes the raw offset
      # and lets `#value=` clamp. Returns `#minimum` for a non-positive span.
      protected def value_at(pos : Int32, span : Int32) : Int32
        return @minimum if span <= 0
        @minimum + (pos.to_f * value_span / span).round.to_i
      end
    end
  end
end
