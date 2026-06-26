require "./abstract_scroll_area"

module Crysterm
  class Widget
    # Abstract base for the item views, modeled after Qt's `QAbstractItemView`.
    #
    # `List` (Qt's `QListWidget`) and `Table` (`QTableWidget`) derive this
    # directly, mirroring Qt where every item view roots in `QAbstractItemView <
    # QAbstractScrollArea`. Crysterm's other item views — `Tree`, `ListTable`,
    # `Menu`, `FileManager`, `ComboBox::Popup` — are built **on `List`** for
    # implementation reuse (a `Tree` *is* a `List` of flattened nodes, etc.), the
    # same deliberate convention documented on `Menu`. They are therefore still
    # `AbstractItemView`s transitively, so `QAbstractItemView { … }` matches every
    # one of them, even though Qt makes `QTreeWidget`/`QTableWidget` siblings of
    # `QListWidget` rather than subclasses.
    #
    # It is a thin grouping base: the selection model, navigation and rendering
    # live in the concrete widgets. Its role here is the shared type that the
    # `QAbstractItemView` selector resolves to.
    abstract class AbstractItemView < AbstractScrollArea
    end
  end
end
