require "./abstract_scroll_area"

module Crysterm
  class Widget
    # Abstract base for the item views, modeled after Qt's `QAbstractItemView`.
    #
    # Thin grouping base: selection model, navigation and rendering live in the
    # concrete widgets. This is just the shared type the selector resolves to.
    abstract class AbstractItemView < AbstractScrollArea
    end
  end
end
