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

      # Prepends node to the list of children
      def prepend(element)
        insert element, 0
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
    end
  end
end
