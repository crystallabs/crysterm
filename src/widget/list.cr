require "./abstract_item_view"
require "../mixin/item_view"

module Crysterm
  class Widget
    #
    # `List` is Crysterm's `QListWidget`: an `AbstractItemView`. The selectable
    # item model itself lives in `Mixin::ItemView`, which the sibling item views
    # (`Tree`, `ListTable`, `ComboBox::Popup`, `FileManager`) and `Menu` also
    # include — so they reuse the rows without inheriting `List`.
    #
    # <!-- widget-examples:capture v1 -->
    # ![List screenshot](../../tests/widget/list/list.5s.apng)
    # <!-- /widget-examples:capture -->
    class List < AbstractItemView
      include Mixin::ItemView
    end
  end
end
