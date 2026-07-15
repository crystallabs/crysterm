require "./input"

module Crysterm
  class Widget
    # Abstract base for the spin-box family, modeled after Qt's `QAbstractSpinBox`.
    #
    # Thin grouping base: a fixed-width, in-place-editable field stepped with
    # Up/Down. Concrete classes supply editing behavior via
    # `Mixin::SpinBoxEditing` (numeric spin boxes) or `Mixin::SectionedField`
    # (date/time editors).
    abstract class AbstractSpinBox < Input
      # A spin box honors its given `width` rather than shrinking to its content.
      @shrink_to_fit = false

      # Indicates focus via reverse-video at the unstyled floor.
      def floor_focus_reverse? : Bool
        true
      end
    end
  end
end
