require "./box"

module Crysterm
  class Widget
    # Abstract base for widgets with a scrollable viewport, modeled after Qt's
    # `QAbstractScrollArea`.
    #
    # Thin grouping base: scroll machinery lives in `Widget` plus per-widget
    # scrollbar-policy defaults; this only gives the family a shared type.
    # Not interactive on its own — editable members opt in via
    # `Mixin::Interactive`.
    abstract class AbstractScrollArea < Box
    end
  end
end
