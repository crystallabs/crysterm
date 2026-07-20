require "../layout_flow"

module Crysterm
  class Layout
    # Masonry / inline flow (blessed's `inline` layout). Children flow
    # left-to-right at their natural widths, wrap to a new row on overflow,
    # then gravitate upward to sit beneath the nearest child on the row above,
    # producing a packed masonry-like arrangement.
    #
    # <!-- widget-examples:capture v1 -->
    # ![Masonry screenshot](../../tests/layout/masonry/masonry.5s.apng)
    # <!-- /widget-examples:capture -->
    class Masonry < Flow
      protected def place_one(container : Widget, el : Widget, i : Int32, interior : RenderedGeometry) : Overflow?
        flow_place container, el, i, interior, 0
        gravitate_up container, el, interior
        overflow_action container, el, interior
      end

      # Pulls `el` up to rest below the child on the previous row whose left
      # edge is nearest its own, avoiding ragged vertical gaps.
      private def gravitate_up(container : Widget, el : Widget, interior : RenderedGeometry) : Nil
        xi = interior.xi
        yi = interior.yi

        above = nil
        abovea = Int32::MAX
        each_rendered_in_range(container, @last_row_index, @row_index) do |l, lp|
          abs = (el.left.as(Int) - (lp.xi - xi)).abs
          if abs < abovea
            above = l
            abovea = abs
          end
        end

        if (ab = above) && (alp = rendered_geometry(ab))
          # `alp.yl - yi` glues `el` flush to the above child's drawn bottom
          # edge; add back its bottom margin so gravitation doesn't collapse
          # it to zero, matching the horizontal chain's additive convention
          # (`flow_place`'s `last.mright`). `Math.min` against the wrap-path
          # top already assigned by `flow_place` means gravitation can only
          # pull `el` up, never push it below its row-assigned position.
          el.top = Math.min(el.top.as(Int), (alp.yl - yi) + ab.mbottom)
        end
      end
    end
  end
end
