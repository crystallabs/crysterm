require "./abstract_item_view"
require "../mixin/item_view"

module Crysterm
  class Widget
    # <!-- widget-examples:capture v1 -->
    # ![List screenshot](../../examples/widget/list/list-capture5s.apng)
    # <!-- /widget-examples:capture -->
    #
    # `List` is Crysterm's `QListWidget`: an `AbstractItemView`. The selectable
    # item model itself lives in `Mixin::ItemView`, which the sibling item views
    # (`Tree`, `ListTable`, `ComboBox::Popup`, `FileManager`) and `Menu` also
    # include — so they reuse the rows without inheriting `List`.
    class List < AbstractItemView
      include Mixin::ItemView
    end
  end
end
