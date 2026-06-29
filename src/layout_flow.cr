require "./layout"

module Crysterm
  class Layout
    # Shared base for the *flow* layouts — `Masonry`, `UniformGrid` and `Wrap`
    # (distinct from `Layout::Grid`, which is a real row/column grid, not a
    # flow). All place children left-to-right, wrapping to a new row when the
    # next child would overflow the interior width; they differ only in column
    # alignment (`UniformGrid` snaps every child to a uniform column width) and
    # in whether lower-row children gravitate upward (`Masonry` only).
    #
    # `Flow` owns the arrange loop — render-index bookkeeping, overflow handling
    # and per-child rendering — and defers the actual per-child positioning to
    # `#place_one`. Children are rendered as they are placed, so a content-sized
    # child's real extent (read back via `#get_last`) is known when positioning
    # the next one. The row cursor (`@row_offset`/`@row_index`/`@last_row_index`)
    # is per-render transient state, so a layout instance belongs to a single
    # container.
    abstract class Flow < Layout
      @row_offset = 0
      @row_index = 0
      @last_row_index = 0

      def arrange(container : Widget, interior : LPos) : Nil
        @row_offset = 0
        @row_index = 0
        @last_row_index = 0
        before_flow container

        children = container.children
        children.each_with_index do |el, i|
          next if el.layout_excluded?
          # Every child consumes a render index, even one we skip below, to
          # match the original loop's z-order bookkeeping.
          bump_index el

          case place_one container, el, i, interior
          when Overflow::SkipWidget
            skip el
            next
          when Overflow::StopRendering
            # `StopRendering` means "leave current *and remaining* widgets
            # unrendered" (see `Overflow`). Clearing only `el`'s `lpos` left every
            # later child carrying its stale rectangle from the previous frame, so
            # a vertically-overflowing flow stayed mouse-clickable / focusable at
            # ghost positions for the rows it never drew. Skip the not-yet-placed
            # children too (their `lpos` is now nil → treated as not present),
            # honoring the contract and the `Overflow` TODO about focus/hit-test.
            # Layout-excluded chrome (e.g. a `background-image` layer) is rendered
            # out-of-band with its own live `lpos`, so it must be left untouched.
            skip el
            j = i + 1
            while j < children.size
              nxt = children[j]
              skip nxt unless nxt.layout_excluded?
              j += 1
            end
            break
          when Overflow::MoveWidget
            # No-op at the layout level: a `MoveWidget` child repositions itself
            # to stay on window during its own render (`Widget#_get_coords`), so
            # fall through and render it where it lands.
          end

          # Honor z-index deferral like the other engines. A deferred (z-indexed)
          # flow child still renders at the position assigned above, but is
          # composited on its own plane, so `get_last` won't see its `lpos` this
          # frame and the next child chains off the previous *inline* child —
          # acceptable for the rare z-indexed flow child.
          render_or_defer el
        end
      end

      # Hook run once before the loop (e.g. `Grid` precomputes its uniform
      # column width here). Default: no-op.
      protected def before_flow(container : Widget) : Nil
      end

      # Positions the `i`-th child within `interior` (setting `left`/`top`) and
      # returns an `Overflow` action if it does not fit, or nil to render it.
      protected abstract def place_one(container : Widget, el : Widget, i : Int32, interior : LPos) : Overflow?

      # Places `el` in the current row, wrapping to a new row when it would
      # overflow `interior`'s width. When `high_width > 0` (grid mode) each child
      # is snapped to a uniform column of that width.
      protected def flow_place(container : Widget, el : Widget, i : Int32, interior : LPos, high_width : Int32) : Nil
        xi = interior.xi
        width = interior.xl - interior.xi

        # Make children resizable so a missing dimension (e.g. height) is
        # computed for them at render time.
        el.resizable = true

        # `get_last` only ever returns a rendered child, so `rendered_lpos` is
        # non-nil whenever `last` is — binding it here drops a `not_nil!` and
        # narrows `llp` to non-nil for the rest of the method.
        last = get_last container, i
        unless last && (llp = rendered_lpos(last))
          el.left = 0
          el.top = 0
          return
        end
        # Chain off `last`'s *outer* right edge: `llp.xl` is its drawn
        # (margin-inset) edge, so add back its right margin. `el` then
        # self-offsets by its own left margin during render (`_get_coords`),
        # giving adjacent flow children `last.margin.right + el.margin.left` of
        # separation (additive; no CSS margin-collapsing). Margins default to 0,
        # so this is a no-op for unmargined children.
        el.left = (llp.xl + last.mright) - xi

        # Snap to the uniform column width in grid mode.
        if high_width > 0
          el.left = el.left.as(Int) + high_width - (llp.xl - llp.xi)
        end

        if el.left.as(Int) + el.awidth <= width
          el.top = @row_offset
        else
          # The next child doesn't fit on this row: advance the row offset by
          # the tallest rendered child on the row we are leaving, and start a
          # new row. Scan the row's index range directly instead of
          # `children[@row_index...i]`, which allocated a slice copy on every
          # wrap.
          tallest = 0
          each_rendered_in_range(container, @row_index, i) do |el2, elp|
            # Outer height: the drawn rect lost its vertical margin to the
            # inset, so add it back, leaving the next row separated by this
            # child's bottom margin plus the next child's top margin.
            eh = (elp.yl - elp.yi) + el2.mheight
            tallest = eh if eh > tallest
          end
          @row_offset += tallest
          @last_row_index = @row_index
          @row_index = i
          el.left = 0
          el.top = @row_offset
        end
      end

      # Yields each child in `container.children[from...to]` that this engine
      # actually arranged and that rendered to a non-empty rectangle, together
      # with that rectangle — the index walk both the row-tallest scan
      # (`#flow_place`) and the upward gravitation (`Masonry#gravitate_up`)
      # otherwise hand-roll identically: skip `layout_excluded?` chrome (a
      # full-interior `background-image` layer rendered out-of-band would wrongly
      # inflate a row or be gravitated under), skip the not-yet/never-rendered,
      # and bind `rendered_lpos`. Block-yielding (no captured `Proc`), so it
      # allocates nothing per frame.
      protected def each_rendered_in_range(container : Widget, from : Int32, to : Int32, &) : Nil
        j = from
        while j < to
          el = container.children[j]
          if !el.layout_excluded? && (lp = rendered_lpos(el))
            yield el, lp
          end
          j += 1
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
