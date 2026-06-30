require "../layout_flow"

module Crysterm
  class Layout
    # Uniform-cell wrapping flow (WPF's `UniformGrid`; blessed's `grid` layout).
    # Like `Masonry` it flows children left-to-right with row wrapping, but every
    # child is snapped to a column of the widest child's width, so the result is
    # a regular tiled grid rather than a packed masonry. For an explicit
    # row/column grid with spans, see `Layout::Grid`.
    #
    # <!-- widget-examples:capture v1 -->
    # ![UniformGrid screenshot](../../tests/layout/uniform_grid/uniform_grid.5s.apng)
    # <!-- /widget-examples:capture -->
    class UniformGrid < Flow
      @high_width = 0

      # Pre-compute the widest child; that becomes the uniform column width.
      # Skip layout-excluded chrome (e.g. a `background-image` layer, which fills
      # the container) — matching `Flow#arrange`'s placement loop, which never
      # arranges those; otherwise such a full-width layer would inflate the
      # uniform column to the whole interior, collapsing the grid to one column.
      protected def before_flow(container : Widget) : Nil
        @high_width = container.children.reduce(0) do |o, el|
          next o if el.layout_excluded?
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
