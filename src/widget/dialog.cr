require "./box"

module Crysterm
  class Widget
    # Abstract base for the dialog family, modeled after Qt's `QDialog`.
    #
    # The concrete dialogs — `ColorDialog` (`QColorDialog`), `Message`
    # (`QMessageBox`), `Question`/`Prompt` (`QInputDialog`) and `Wizard`
    # (`QWizard`) — derive this, mirroring Qt where every standard dialog is a
    # `QDialog` subclass. (`DialogButtonBox` deliberately does **not**: Qt's
    # `QDialogButtonBox` is a plain `QWidget`, so it stays a `Box`.)
    #
    # It is a thin grouping base over `Box`: it adds no behavior of its own (the
    # individual dialogs supply their own layout, buttons and modality), but
    # gives the family a shared type so a `Dialog { … }` selector — and Qt's
    # `QDialog` selector — matches every dialog at once.
    abstract class Dialog < Box
      # Dialogs are overlays: at the unstyled floor (no theme/CSS) they carry a
      # structural border so they separate from the content behind them. Any
      # active theme makes the dialog `css_styled`, so it can override or remove
      # this freely (see `Mixin::Style#floor_border?`).
      def floor_border? : Bool
        true
      end
    end
  end
end
