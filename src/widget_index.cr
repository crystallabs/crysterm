module Crysterm
  class Widget
    # Widget's position in the stack (front, back). Render index / order.

    property index = -1

    # Sends widget to front
    def front!
      set_index -1
    end

    # Sends widget to back
    def back!
      set_index 0
    end

    def set_index(index : Int)
      # A top-level widget is held in `Window#children` but has no `@parent`
      # (a `Window` is not a `Widget`), so fall back to the window — otherwise
      # `front!`/`back!` would silently do nothing for window-level widgets.
      return unless parent = (@parent || window?)

      if index < 0
        index = parent.children.size + index
      end

      index = Math.max index, 0
      index = Math.min index, parent.children.size - 1

      i = parent.children.index self

      return unless i

      parent.children.insert index, parent.children.delete_at i

      true
    end
  end
end
