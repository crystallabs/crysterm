require "./abstract_scroll_area"

module Crysterm
  class Widget
    # Abstract base for the item views, modeled after Qt's `QAbstractItemView`.
    #
    # `List` and `Table` derive this directly, mirroring Qt's
    # `QAbstractItemView < QAbstractScrollArea`. Other item views (`Tree`,
    # `ListTable`, `Menu`, `FileManager`, `ComboBox::Popup`) are built on `List`
    # for implementation reuse (see `Menu`), so they remain `AbstractItemView`s
    # transitively even though Qt makes `QTreeWidget`/`QTableWidget` siblings of
    # `QListWidget` rather than subclasses.
    #
    # Thin grouping base: selection model, navigation and rendering live in the
    # concrete widgets. This is just the shared type the selector resolves to.
    abstract class AbstractItemView < AbstractScrollArea
    end
  end
end
