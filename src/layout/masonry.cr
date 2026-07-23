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
          # A deferred (z-indexed) child's `lpos` still holds the PREVIOUS
          # frame's rect until plane compositing, so its `lp.xi` is stale this
          # frame. Take its left edge from assigned geometry instead — the same
          # fall-through `flow_place` uses for a deferred predecessor; in steady
          # state both give the same edge.
          left = deferred_this_frame?(l) ? l.left.as(Int) + l.mleft : lp.xi - xi
          abs = (el.left.as(Int) - left).abs
          if abs < abovea
            above = l
            abovea = abs
          end
        end

        if ab = above
          # The above child's drawn bottom edge (`alp.yl - yi`) glues `el` flush
          # beneath it; add back its bottom margin so gravitation doesn't
          # collapse to zero, matching the horizontal chain's additive
          # convention (`flow_place`'s `last.mright`). A deferred above-child's
          # `lpos` is stale this frame, so anchor on its assigned geometry
          # (`top + mtop + occupied_height + mbottom` — `occupied_height`, not
          # `aheight`, so a shrink-to-fit deferred child anchors at its drawn
          # height rather than the stretched interior), which equals the
          # painted edge in steady state. `Math.min` against the wrap-path top
          # already assigned by `flow_place` means gravitation can only pull
          # `el` up, never push it below its row-assigned position.
          bottom =
            if deferred_this_frame?(ab)
              ab.top.as(Int) + ab.mtop + occupied_height(ab) + ab.mbottom
            elsif alp = rendered_geometry(ab)
              (alp.yl - yi) + ab.mbottom
            end
          el.top = Math.min(el.top.as(Int), bottom) if bottom
        end
      end
    end
  end
end
