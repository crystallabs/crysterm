require "./box"

module Crysterm
  class Widget
    # Abstract base for widgets with a scrollable viewport, modeled after Qt's
    # `QAbstractScrollArea`.
    #
    # `ScrollableBox` (`QScrollArea`), `PlainTextEdit` (`QPlainTextEdit`), and
    # `AbstractItemView` (list/tree/table base) all derive this, mirroring Qt's
    # `QAbstractScrollArea < QFrame` hierarchy (Crysterm's `Box` plays `QFrame`).
    #
    # Thin grouping base: scroll machinery lives in `Widget` (`widget_scrolling.cr`)
    # plus per-widget scrollbar-policy defaults; this only gives the family a
    # shared type for `QAbstractScrollArea` selectors. Not interactive on its own
    # (Qt's scroll areas aren't focusable by default) — editable members opt in
    # via `Mixin::Interactive`.
    abstract class AbstractScrollArea < Box
    end
  end
end
