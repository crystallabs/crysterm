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
      # Compact, reused snapshot of the previous row: each entry is
      # `{left, bottom}` in interior-local cells, in left-to-right child order.
      # `#gravitate_up` runs per child but the row above is the same for every
      # child of the current row, so it is scanned/measured once per row (when
      # `@row_key` changes) instead of re-walking + re-testing every previous-row
      # widget for every current-row child (the O(row²) rescan).
      @prev_row = [] of Tuple(Int32, Int32)
      # `{@last_row_index, @row_index}` the snapshot was built for; `{-1, -1}`
      # forces a rebuild. Reset each frame in `#before_flow`, since the same
      # index pair recurs across frames with different rendered rects.
      @row_key = {-1, -1}

      protected def before_flow(container : Widget) : Nil
        @row_key = {-1, -1}
      end

      protected def place_one(container : Widget, el : Widget, i : Int32, interior : RenderedGeometry) : Overflow?
        flow_place container, el, i, interior, 0
        gravitate_up container, el, interior
        overflow_action container, el, interior
      end

      # Pulls `el` up to rest below the child on the previous row whose left
      # edge is nearest its own, avoiding ragged vertical gaps.
      private def gravitate_up(container : Widget, el : Widget, interior : RenderedGeometry) : Nil
        key = {@last_row_index, @row_index}
        if key != @row_key
          rebuild_prev_row container, interior
          @row_key = key
        end

        # Linear scan of the compact snapshot (Int32 tuples, no widget walk or
        # `arrangeable?`/`rendered_geometry` re-test), keeping the tie-break of
        # the *first* previous-row child with minimal `abs(el.left - left)`.
        row = @prev_row
        return if row.empty?
        el_left = el.left.as(Int)
        best_bottom = 0
        abovea = Int32::MAX
        i = 0
        n = row.size
        while i < n
          entry = row.unsafe_fetch(i)
          abs = (el_left - entry[0]).abs
          if abs < abovea
            abovea = abs
            best_bottom = entry[1]
          end
          i += 1
        end
        if abovea != Int32::MAX
          # `Math.min` against the wrap-path top already assigned by
          # `flow_place` means gravitation can only pull `el` up, never push it
          # below its row-assigned position.
          el.top = Math.min(el.top.as(Int), best_bottom)
        end
      end

      # Snapshots the previous row (`[@last_row_index, @row_index)`) into
      # `@prev_row` once: for each rendered child, its interior-local left edge
      # and the bottom edge to glue successors beneath.
      private def rebuild_prev_row(container : Widget, interior : RenderedGeometry) : Nil
        xi = interior.xi
        yi = interior.yi
        @prev_row.clear
        each_rendered_in_range(container, @last_row_index, @row_index) do |l, lp|
          # A deferred (z-indexed) child's `lpos` still holds the PREVIOUS
          # frame's rect until plane compositing, so its `lp.xi`/`lp.yl` are
          # stale this frame. Take its edges from assigned geometry instead —
          # the same fall-through `flow_place`/the old inline path used; in
          # steady state both give the same edges.
          if deferred_this_frame?(l)
            left = l.left.as(Int) + l.mleft
            # The above child's assigned bottom edge (`top + mtop +
            # occupied_height + mbottom` — `occupied_height`, not `aheight`, so a
            # shrink-to-fit deferred child anchors at its drawn height rather
            # than the stretched interior), which equals the painted edge in
            # steady state. B18-25: widen to Int64 and clamp to the interior so
            # a pathological extent can't overflow the checked Int32 sum.
            bottom = (l.top.as(Int).to_i64 + l.mtop + occupied_height(l) + l.mbottom).clamp(0_i64, interior.height.to_i64).to_i32
          else
            left = lp.xi - xi
            # The drawn bottom edge (`lp.yl - yi`) glues `el` flush beneath it;
            # add back its bottom margin so gravitation doesn't collapse to
            # zero, matching the horizontal chain's additive convention
            # (`flow_place`'s `last.mright`).
            bottom = (lp.yl - yi) + l.mbottom
          end
          @prev_row << {left, bottom}
        end
      end
    end
  end
end
