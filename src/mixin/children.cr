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

      # Appends `element`s to list of children in the order given (first listed is first added)
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
        element.clear_last_rendered_position
        @children.delete_at i
      end

      # Returns true if `obj` is found in the list of parents, recursively
      def has_ancestor?(obj)
        el = self
        while el = el.parent
          return true if el.same? obj
        end
        false
      end

      # Returns true if `obj` is found in the list of children, recursively
      def has_descendant?(obj)
        @children.each do |el|
          return true if el.same? obj
          return true if el.descendant? obj
        end
        false
      end

      # Runs a particular block for self and all descendants, recursively
      def self_and_each_descendant(&block : Proc(Widget, Nil)) : Nil
        block.call self
        each_descendant &block
      end

      # Runs a particular block for all descendants, recursively
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

      # Runs a particular block for self and all ancestors, recursively
      def self_and_each_ancestor(&block : Proc(Widget, Nil)) : Nil
        block.call self
        each_ancestor &block
      end

      # Runs a particular block for all ancestors, recursively
      def each_ancestor(&block : Proc(Widget, Nil)) : Nil
        f = uninitialized Widget -> Nil
        f = ->(el : Widget) {
          block.call el
          el.parent.try { |el2| f.call el2 }
        }

        @parent.try { |el| f.call el }
      end

      # Returns a flat list of all children widgets, recursively
      def collect_descendants(el : Widget) : Array(Widget)
        children = [] of Widget
        each_descendant { |e| children << e }
        children
      end

      # Returns a flat list of all parent widgets, recursively
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
