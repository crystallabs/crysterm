require "./box"

module Crysterm
  class Widget
    # Abstract base for widgets with a scrollable viewport, modeled after Qt's
    # `QAbstractScrollArea`.
    #
    # `ScrollableBox` (Qt's `QScrollArea`), `PlainTextEdit` (`QPlainTextEdit`),
    # and `AbstractItemView` (the list/tree/table base) all derive this — exactly
    # as Qt roots `QScrollArea`/`QPlainTextEdit`/`QTextEdit`/`QAbstractItemView`
    # in `QAbstractScrollArea < QFrame`. (Crysterm's `Box` plays the `QFrame`
    # role.)
    #
    # It is a thin grouping base: the concrete scroll machinery lives in the base
    # `Widget` (`widget_scrolling.cr`) and the per-widget scrollbar-policy
    # defaults, so this only gives the family a shared type for `QAbstractScrollArea`
    # selectors to match. Note it is *not* interactive on its own (Qt's scroll
    # areas are not focusable by default); the editable members opt in via
    # `Mixin::Interactive`.
    abstract class AbstractScrollArea < Box
    end
  end
end
