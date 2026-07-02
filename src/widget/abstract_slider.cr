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

      # `Slider`/`Dial` indicate focus via reverse-video at the unstyled floor
      # (see `Mixin::Style#floor_focus_reverse?`), same as the button family.
      def floor_focus_reverse? : Bool
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
        @minimum + (pos * value_span / span.to_f).round.to_i
      end
    end
  end
end
