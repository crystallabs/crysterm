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
    end
  end
end
