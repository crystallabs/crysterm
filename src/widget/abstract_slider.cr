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
    end
  end
end
