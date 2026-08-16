require "./abstract_interactive"

module Crysterm
  class Widget
    # Abstract base for the spin-box family, modeled after Qt's `QAbstractSpinBox`.
    #
    # Thin grouping base: a fixed-width, in-place-editable field stepped with
    # Up/Down. Concrete classes supply editing behavior via
    # `Mixin::SpinBoxEditing` (numeric spin boxes) or `Mixin::SectionedField`
    # (date/time editors).
    abstract class AbstractSpinBox < AbstractInteractive
      # A spin box honors its given `width` rather than shrinking to its content.
      @shrink_to_fit = false

      # Empties the displayed edit text — Qt's `QAbstractSpinBox#clear`; the
      # committed value is untouched. Here at the family root it is a
      # no-op: the sectioned date/time editors always display a valid value
      # and keep no free-text buffer to blank. `Mixin::SpinBoxEditing`
      # overrides it for the numeric boxes (`SpinBox`/`DoubleSpinBox`) by
      # blanking their edit buffer.
      def clear
      end

      # Indicates focus via reverse-video at the unstyled floor.
      def floor_focus_reverse? : Bool
        true
      end
    end
  end
end
