require "./input"

module Crysterm
  class Widget
    # Abstract base for the spin-box family, modeled after Qt's `QAbstractSpinBox`.
    #
    # `SpinBox`, `DoubleSpinBox` and `DateTimeEdit` derive this directly
    # (siblings, as in Qt); `DateEdit` and `TimeEdit` in turn derive
    # `DateTimeEdit`, mirroring Qt's `QDateEdit`/`QTimeEdit < QDateTimeEdit`.
    #
    # It is a thin grouping base: the concrete classes still supply their own
    # editing behavior through the appropriate mixin (`Mixin::SpinBoxEditing` for
    # the numeric spin boxes, `Mixin::SectionedField` for the date/time editors),
    # since Qt's single `stepBy`/edit frame maps onto two different Crysterm
    # editing strategies. What unifies them here is only the shared identity —
    # a fixed-width, in-place-editable field stepped with Up/Down — which is what
    # the `QAbstractSpinBox` selector should match.
    abstract class AbstractSpinBox < Input
      # `SpinBox` indicates focus via reverse-video at the unstyled floor (see
      # `Mixin::Style#floor_focus_reverse?`): like the button family it is a
      # small, single-line control, so inverting it is the clearest no-color
      # focus cue.
      def floor_focus_reverse? : Bool
        true
      end
    end
  end
end
