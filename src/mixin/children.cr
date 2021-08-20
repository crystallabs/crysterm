module Crysterm
  module Mixin
    module Children
      # Widget's children `Widget`s.
      getter children = [] of Widget

      def <<(widget : Widget)
        append widget
      end

      def >>(widget : Widget)
        remove widget
      end

      # Appends `element` to list of children
      def append(element)
        insert element
      end

      # Appends `element`s to list of children in order of specification
      def append(*elements)
        elements.each do |el|
          insert el
        end
      end

      # Prepends node to the list of children
      def prepend(element)
        insert element, 0
      end

      # Adds node to the list of children before the specified `other` element
      def insert_before(element, other)
        if i = @children.index other
          insert element, i
        end
      end

      # Adds node to the list of children after the specified `other` element
      def insert_after(element, other)
        if i = @children.index other
          insert element, i + 1
        end
      end

      # Inserts `element` into list of children widgets
      def insert(element, i = -1)
        @children.insert i, element
      end

      # Removes `element` from list of children widgets
      def remove(element)
        return unless i = @children.index(element)
        element.clear_pos
        @children.delete_at i
      end

      def ancestor?(obj)
        el = self
        while el = el.parent
          return true if el == obj
        end
        false
      end

      def descendant?(obj)
        @children.each do |el|
          return true if el == obj
          return true if el.descendant? obj
        end
        false
      end

      def self_and_each_descendant(&block : Proc(Widget, Nil)) : Nil
        block.call self
        each_descendant &block
      end

      def each_descendant(&block : Proc(Widget, Nil)) : Nil
        f = uninitialized Widget -> Nil
        f = ->(el : Widget) {
          block.call el
          el.children.each do |c|
            f.call c
          end
        }

        @children.each do |el|
          f.call el
        end
      end

      def each_ancestor(with_self : Bool = false) : Nil
        yield self if with_self

        el = self
        while el = el.parent
          yield el
        end
      end

      def collect_descendants(el : Widget) : Array(Widget)
        children = [] of Widget
        each_descendant { |e| children << e }
        children
      end

      def collect_ancestors(el : Widget) : Array(Widget)
        parents = [] of Widget
        each_ancestor { |e| parents << e }
        parents
      end

      # Emits `ev` on all children nodes, recursively.
      def emit_descendants(ev : EventHandler::Event | EventHandler::Event.class) : Nil
        each_descendant { |el| el.emit ev }
      end

      # Emits `ev` on all parent nodes.
      def emit_ancestors(ev : EventHandler::Event | EventHandler::Event.class) : Nil
        each_ancestor { |el| el.emit ev }
      end
    end
  end
end
