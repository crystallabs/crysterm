require "./flow"

module Crysterm
  class Layout
    # Uniform grid (blessed's `grid` layout). Like `Masonry` it flows children
    # left-to-right with row wrapping, but every child is snapped to a column of
    # the widest child's width, so the result is a regular table-like grid
    # rather than a packed masonry.
    class Grid < Flow
      @high_width = 0

      # Pre-compute the widest child; that becomes the uniform column width.
      protected def before_flow(container : Widget) : Nil
        @high_width = container.children.reduce(0) do |o, el|
          Math.max o, el.awidth
        end
      end

      protected def place_one(container : Widget, el : Widget, i : Int32, interior : LPos) : Overflow?
        flow_place container, el, i, interior, @high_width
        overflow_action container, el, interior
      end
    end
  end
end
