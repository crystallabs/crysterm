require "./layout"

module Crysterm
  class Layout
    # Shared base for the two *flow* layouts, `Masonry` and `Grid`. Both place
    # children left-to-right, wrapping to a new row when the next child would
    # overflow the interior width; they differ only in column alignment (grid
    # snaps every child to a uniform column width) and in whether lower-row
    # children gravitate upward (masonry only).
    #
    # The row cursor (`@row_offset`/`@row_index`/`@last_row_index`) is per-render
    # transient state, reset by `#before_children`. A layout instance therefore
    # belongs to a single container.
    abstract class Flow < Layout
      @row_offset = 0
      @row_index = 0
      @last_row_index = 0

      def before_children(container : Widget, interior : LPos) : Nil
        @row_offset = 0
        @row_index = 0
        @last_row_index = 0
      end

      # Places `el` in the current row, wrapping to a new row when it would
      # overflow `interior`'s width. When `high_width > 0` (grid mode) each child
      # is snapped to a uniform column of that width.
      protected def flow_place(container : Widget, el : Widget, i : Int32, interior : LPos, high_width : Int32) : Nil
        xi = interior.xi
        width = interior.xl - interior.xi

        # Make children resizable so a missing dimension (e.g. height) is
        # computed for them at render time.
        el.resizable = true

        last = get_last container, i
        if !last
          el.left = 0
          el.top = 0
          return
        end

        llp = last.lpos.not_nil!
        el.left = llp.xl - xi

        # Snap to the uniform column width in grid mode.
        if high_width > 0
          el.left = el.left.as(Int) + high_width - (llp.xl - llp.xi)
        end

        if el.left.as(Int) + el.awidth <= width
          el.top = @row_offset
        else
          # The next child doesn't fit on this row: advance the row offset by
          # the tallest rendered child on the row we are leaving, and start a
          # new row.
          @row_offset += container.children[@row_index...i].reduce(0) do |o, el2|
            if !rendered? el2
              o
            else
              elp = el2.lpos.not_nil!
              Math.max o, elp.yl - elp.yi
            end
          end
          @last_row_index = @row_index
          @row_index = i
          el.left = 0
          el.top = @row_offset
        end
      end

      # Returns the container's `overflow` action if `el` extends past the
      # interior's bottom edge, otherwise nil. Uses the *computed* `aheight`
      # (rather than the raw `height`) so a child with no explicit/`nil`/percent
      # height — legal here, since flow children are made `resizable` — is
      # measured instead of raising on an `.as(Int)` cast.
      protected def overflow_action(container : Widget, el : Widget, interior : LPos) : Overflow?
        height = interior.yl - interior.yi
        if el.top.as(Int) + el.aheight > height
          return container.overflow
        end
        nil
      end
    end
  end
end
