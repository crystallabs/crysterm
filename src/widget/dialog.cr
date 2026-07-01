require "./box"

module Crysterm
  class Widget
    # Abstract base for the dialog family, modeled after Qt's `QDialog`.
    #
    # `ColorDialog`, `Message`, `Question`/`Prompt` and `Wizard` derive this,
    # mirroring Qt where every standard dialog is a `QDialog` subclass.
    # (`DialogButtonBox` does *not*: Qt's `QDialogButtonBox` is a plain
    # `QWidget`, so it stays a `Box`.)
    #
    # Thin grouping base over `Box` with no behavior of its own; gives the
    # family a shared type so a `Dialog { … }` selector matches every dialog.
    abstract class Dialog < Box
      # Dialogs are overlays: at the unstyled floor they carry a structural
      # border to separate from content behind them. An active theme can
      # override/remove this via `Mixin::Style#floor_border?`.
      def floor_border? : Bool
        true
      end
    end
  end
end
