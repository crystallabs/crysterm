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

      # The raw row mutators are `protected` in `Mixin::ItemView` (on the
      # model-backed views — `Tree`, `Menu`, `ListTable`, … — a raw row is
      # silently wiped by the next model rebuild). `List` is the view whose
      # model *is* these rows, so here they are the real public API,
      # re-publicized one `super` at a time.
      def add_item(content : String)
        super
      end

      # :ditto:
      def add_item(widget : Widget)
        super
      end

      # :ditto:
      def <<(content : String)
        super
      end

      # :ditto:
      def insert_item(index : Int, content : String)
        super
      end

      # :ditto:
      def insert_item(child : String | Widget, content : String)
        super
      end

      # :ditto:
      def remove_item(child)
        super
      end

      # :ditto:
      def set_item(child, content : String)
        super
      end

      # :ditto:
      def set_item(child, widget : Widget)
        super
      end

      # :ditto:
      def items=(items : Array(String))
        super
      end

      # :ditto:
      def clear
        super
      end
    end
  end
end
