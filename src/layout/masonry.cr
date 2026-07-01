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
      protected def place_one(container : Widget, el : Widget, i : Int32, interior : LPos) : Overflow?
        flow_place container, el, i, interior, 0
        gravitate_up container, el, interior
        overflow_action container, el, interior
      end

      # Pulls `el` up to rest below the child on the previous row whose left
      # edge is nearest its own, avoiding ragged vertical gaps.
      private def gravitate_up(container : Widget, el : Widget, interior : LPos) : Nil
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

        if (ab = above) && (alp = rendered_lpos(ab))
          el.top = alp.yl - yi
        end
      end
    end
  end
end
