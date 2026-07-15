require "../layout_flow"

module Crysterm
  class Layout
    # Uniform-cell wrapping flow (WPF's `UniformGrid`; blessed's `grid` layout).
    # Like `Masonry`, flows children left-to-right with row wrapping, but every
    # child snaps to a column of the widest child's width, giving a regular
    # tiled grid rather than a packed masonry. For an explicit row/column grid
    # with spans, see `Layout::Grid`.
    #
    # NOTE: children must have an explicit `width`. A nil-width (`auto`) child's
    # `awidth` reports the *stretched* full-interior size, which would make it
    # the uniform column width and collapse the grid to a single column.
    #
    # <!-- widget-examples:capture v1 -->
    # ![UniformGrid screenshot](../../tests/layout/uniform_grid/uniform_grid.5s.apng)
    # <!-- /widget-examples:capture -->
    class UniformGrid < Flow
      @high_width = 0

      # Widest child becomes the uniform column width. Skips layout-excluded
      # chrome (e.g. a full-width `background-image` layer), matching
      # `Flow#arrange`'s placement loop, otherwise such a layer would inflate
      # the column to the whole interior and collapse the grid to one column.
      protected def before_flow(container : Widget) : Nil
        @high_width = container.children.reduce(0) do |o, el|
          next o if el.layout_excluded?
          Math.max o, el.awidth
        end
      end

      protected def place_one(container : Widget, el : Widget, i : Int32, interior : RenderedGeometry) : Overflow?
        flow_place container, el, i, interior, @high_width
        overflow_action container, el, interior
      end
    end
  end
end
