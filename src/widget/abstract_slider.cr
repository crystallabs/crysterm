require "./input"
require "../mixin/ranged_value"

module Crysterm
  class Widget
    # Abstract base for the slider family, modeled after Qt's `QAbstractSlider`.
    #
    # `Slider`, `ScrollBar` and `Dial` derive this directly — siblings, exactly
    # as Qt makes `QSlider`/`QScrollBar`/`QDial` siblings under
    # `QAbstractSlider` (rather than chaining one off another). It holds the
    # shared bounded-integer value/range behavior (`#minimum`/`#maximum`/
    # `#value`/`#step`/`#page_step`/`#wrap?`, `#increment`/`#decrement`,
    # `Event::ValueChange`) via `Mixin::RangedValue`, included here once so every
    # member inherits it.
    #
    # `ProgressBar` deliberately does **not** derive this: Qt's `QProgressBar`
    # is a plain `QWidget`, not a `QAbstractSlider`, so it keeps its own range.
    abstract class AbstractSlider < Input
      include Mixin::RangedValue

      # `Slider`/`Dial` indicate focus via reverse-video at the unstyled floor
      # (see `Mixin::Style#floor_focus_reverse?`): like the button family they
      # are small, single-line controls, so inverting them is the clearest
      # no-color focus cue.
      def floor_focus_reverse? : Bool
        true
      end
    end
  end
end
