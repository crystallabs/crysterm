require "./abstract_item_view"
require "../mixin/item_view"

module Crysterm
  class Widget
    # A list of selectable items, modeled after Qt's `QListWidget`.
    #
    # The item model itself lives in `Mixin::ItemView`.
    #
    # <!-- widget-examples:capture v1 -->
    # ![List screenshot](../../tests/widget/list/list.5s.apng)
    # <!-- /widget-examples:capture -->
    class List < AbstractItemView
      include Mixin::ItemView
    end
  end
end
