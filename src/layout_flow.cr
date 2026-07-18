require "./layout"

module Crysterm
  class Layout
    # Shared base for the *flow* layouts — `Masonry`, `UniformGrid` and `Wrap`
    # (distinct from `Layout::Grid`, a real row/column grid). All place children
    # left-to-right, wrapping to a new row when the next child would overflow
    # the interior width; they differ only in column alignment (`UniformGrid`
    # snaps every child to a uniform column width) and in whether lower-row
    # children gravitate upward (`Masonry` only).
    #
    # `Flow` owns the arrange loop — render-index bookkeeping, overflow handling
    # and per-child rendering — and defers per-child positioning to `#place_one`.
    # Children are rendered as they are placed, so a content-sized child's real
    # extent is known when positioning the next one. The row cursor
    # (`@row_offset`/`@row_index`/`@last_row_index`) is per-render transient
    # state, so a layout instance belongs to a single container.
    abstract class Flow < Layout
      @row_offset = 0
      @row_index = 0
      @last_row_index = 0
      # The previous *arranged* child this frame, whether or not it rendered.
      # `#flow_place` normally chains off the last *rendered* child, but one that
      # was placed yet produced no `lpos` (e.g. scroll-clipped above the viewport)
      # would break the chain and collapse every later child to the interior
      # origin; the immediate predecessor lets it continue off assigned geometry.
      @prev_el : Widget? = nil

      def arrange(container : Widget, interior : RenderedGeometry) : Nil
        @row_offset = 0
        @row_index = 0
        @last_row_index = 0
        @prev_el = nil
        before_flow container

        children = container.children
        children.each_with_index do |el, i|
          next if el.layout_excluded?
          # Every child consumes a render index, even one we skip below, to
          # keep z-order bookkeeping consistent.
          bump_index el

          case place_one container, el, i, interior
          when Overflow::SkipWidget
            skip_subtree el
            next
          when Overflow::StopRendering
            # Skip the not-yet-placed children too, nilling their `lpos`, so an
            # overflowing flow doesn't stay mouse-clickable/focusable at last
            # frame's stale positions. Whole subtrees, since hit-testing checks
            # every descendant against its own `lpos`. Layout-excluded chrome
            # renders out-of-band with a live `lpos` and is left untouched.
            skip_subtree el
            j = i + 1
            while j < children.size
              nxt = children[j]
              skip_subtree nxt unless nxt.layout_excluded?
              j += 1
            end
            break
          when Overflow::MoveWidget
            # Translate the child back into the container interior on the
            # overflow (vertical) axis — the interior-scoped analogue of
            # `translate_into_bounds`. A non-Window container's `overflow` is
            # never inherited by the child (`Widget#overflow` resolves to
            # `@overflow || window.overflow || Ignore`), so the child would NOT
            # self-move in its own render; without this the branch behaves like
            # Ignore. Anchor the child's whole margin box within the interior.
            el.top = Math.max(0, interior.height - el.mvertical - el.aheight)
          end

          # A deferred (z-indexed) child still renders at the position assigned
          # above but composites on its own plane, so the next child's chain
          # won't see its `lpos` this frame.
          render_or_defer el
          @prev_el = el
        end
      end

      # Hook run once before the loop (e.g. `Grid` precomputes its uniform
      # column width here). Default: no-op.
      protected def before_flow(container : Widget) : Nil
      end

      # Positions the `i`-th child within `interior` (setting `left`/`top`) and
      # returns an `Overflow` action if it does not fit, or nil to render it.
      protected abstract def place_one(container : Widget, el : Widget, i : Int32, interior : RenderedGeometry) : Overflow?

      # Places `el` in the current row, wrapping to a new row when it would
      # overflow `interior`'s width. When `high_width > 0` (grid mode) each child
      # is snapped to a uniform column of that width.
      protected def flow_place(container : Widget, el : Widget, i : Int32, interior : RenderedGeometry, high_width : Int32) : Nil
        xi = interior.xi
        width = interior.width

        # Make children shrink_to_fit so a missing dimension (e.g. height) is
        # computed for them at render time.
        el.shrink_to_fit = true

        # Chain off the previous child's outer right edge. `llp.xl` is its drawn
        # (margin-inset) edge, so add back its right margin; `el` self-offsets by
        # its own left margin during render, giving adjacent children
        # `last.margin.right + el.margin.left` separation (additive — no CSS
        # margin-collapsing).
        #
        # If nothing rendered before `i` but the immediate predecessor *was*
        # placed (scroll-clipping nil'd its `lpos`), chain off its assigned
        # geometry; otherwise a scrolled flow blanks as every child re-piles at
        # (0, 0). Only a genuine absence of a predecessor falls through to origin.
        if (last = last_rendered_before container, i) && (llp = rendered_geometry(last))
          el.left = (llp.xl + last.mright) - xi
          last_drawn = llp.xl - llp.xi
        elsif (last = @prev_el)
          el.left = last.left.as(Int) + last.mleft + last.awidth + last.mright
          last_drawn = last.awidth
        else
          # No predecessor at all: start the row at the origin. `top` is
          # `@row_offset` (the current row), not a hardcoded 0, so a mid-flow
          # chain break can't fold later rows back onto row 0.
          el.left = 0
          el.top = @row_offset
          return
        end

        # Snap to the uniform column width in grid mode.
        if high_width > 0
          el.left = el.left.as(Int) + high_width - last_drawn
        end

        # Include the child's own left margin: render shifts the drawn box right
        # by `mleft` without shrinking a fixed width, so the child occupies
        # `[left + mleft, left + mleft + awidth)`. Omitting it lets a margined
        # child paint past the interior instead of wrapping.
        if el.left.as(Int) + el.mleft + el.awidth <= width
          el.top = @row_offset
        else
          # Doesn't fit on this row: advance the row offset by the tallest child
          # on the row we're leaving, and start a new row.
          @row_offset += row_tallest container, @row_index, i
          @last_row_index = @row_index
          @row_index = i
          el.left = 0
          el.top = @row_offset
        end
      end

      # Tallest *outer* height among the arranged children in `[from, to)`, used
      # to advance `@row_offset` on wrap. A rendered child contributes its drawn
      # rect height; a placed-but-unrendered (scroll-clipped) one contributes its
      # assigned `aheight`, both plus vertical margin. Without that fallback the
      # cursor stalls at 0 for a fully-clipped row, re-piling later rows onto it.
      protected def row_tallest(container : Widget, from : Int32, to : Int32) : Int32
        tallest = 0
        j = from
        while j < to
          el = container.children[j]
          unless el.layout_excluded?
            eh =
              if lp = rendered_geometry(el)
                (lp.yl - lp.yi) + el.mvertical
              else
                el.aheight + el.mvertical
              end
            tallest = eh if eh > tallest
          end
          j += 1
        end
        tallest
      end

      # Yields each child in `container.children[from...to]` that this engine
      # arranged and rendered to a non-empty rectangle, with that rectangle;
      # `layout_excluded?` chrome and unrendered children are skipped.
      # Block-yielding, so it allocates nothing per frame.
      protected def each_rendered_in_range(container : Widget, from : Int32, to : Int32, &) : Nil
        j = from
        while j < to
          el = container.children[j]
          if !el.layout_excluded? && (lp = rendered_geometry(el))
            yield el, lp
          end
          j += 1
        end
      end

      # Returns the container's `overflow` action if `el` extends past the
      # interior's bottom edge, otherwise nil. Uses the computed `aheight` rather
      # than raw `height` so a nil/percent-height child (legal here, since flow
      # children are `shrink_to_fit`) is measured instead of raising on `.as(Int)`.
      #
      # NOTE: an auto-height child's `aheight` fills the interior remaining
      # *below* `el.top`, so `el.top + aheight` collapses to exactly the interior
      # height and never exceeds it. A nil-height flow child is therefore never
      # reported as overflowing — `SkipWidget`/`StopRendering` need an explicit
      # child height, the vertical analogue of the explicit width flow already
      # requires.
      protected def overflow_action(container : Widget, el : Widget, interior : RenderedGeometry) : Overflow?
        height = interior.height
        # Include the top margin: render shifts a fixed-size box down by `mtop`
        # without shrinking it, so its real bottom edge is `top + mtop + aheight`.
        # Safe for auto-height children too — their `aheight` already folds both
        # vertical margins in, so adding `mtop` still can't exceed the interior.
        if el.top.as(Int) + el.mtop + el.aheight > height
          return container.overflow
        end
        nil
      end
    end
  end
end
