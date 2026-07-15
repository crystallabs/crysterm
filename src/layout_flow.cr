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
    # extent (read back via `#last_rendered_before`) is known when positioning the next one.
    # The row cursor (`@row_offset`/`@row_index`/`@last_row_index`) is per-render
    # transient state, so a layout instance belongs to a single container.
    abstract class Flow < Layout
      @row_offset = 0
      @row_index = 0
      @last_row_index = 0
      # The previous *arranged* flow child this frame (whether or not it
      # rendered). The chain in `#flow_place` normally follows the last
      # *rendered* child (`last_rendered_before`), but a child that was placed yet produced
      # no `lpos` this frame — e.g. scroll-clipped above the viewport — would
      # break that chain and collapse every later child back to the interior
      # origin. Keeping the immediate predecessor lets the chain continue off
      # its assigned geometry instead. Reset each `arrange` (transient
      # per-render state; a Flow instance serves a single container).
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
            # `StopRendering` means "leave current and remaining widgets
            # unrendered" (see `Overflow`). Skip the not-yet-placed children too
            # (their `lpos` becomes nil, treated as not present) so a
            # vertically-overflowing flow doesn't stay mouse-clickable/focusable
            # at stale positions from the previous frame — whole subtrees, since
            # `widget_at` hit-tests every descendant independently against its
            # own `lpos`. Layout-excluded chrome (e.g. a `background-image`
            # layer) renders out-of-band with its own live `lpos`, so it's left
            # untouched.
            skip_subtree el
            j = i + 1
            while j < children.size
              nxt = children[j]
              skip_subtree nxt unless nxt.layout_excluded?
              j += 1
            end
            break
          when Overflow::MoveWidget
            # No-op here: the child repositions itself to stay on window during
            # its own render (`Widget#coords`); fall through and render it
            # where it lands.
          end

          # Honor z-index deferral like the other engines. A deferred (z-indexed)
          # flow child still renders at the position assigned above but is
          # composited on its own plane, so `last_rendered_before` won't see its `lpos` this
          # frame — acceptable for the rare z-indexed flow child.
          render_or_defer el
          # Record this placed child as the chain predecessor for the next one,
          # so a scroll-clipped child (no `lpos` after render) doesn't strand
          # the rest of the flow at the origin. Skipped children (`SkipWidget`/
          # `StopRendering`, handled above) never reach here.
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
        width = interior.xl - interior.xi

        # Make children shrink_to_fit so a missing dimension (e.g. height) is
        # computed for them at render time.
        el.shrink_to_fit = true

        # Chain off the previous child's outer right edge. Normally that's the
        # last *rendered* child (`last_rendered_before`, which also skips children that
        # collapsed to nothing): `llp.xl` is its drawn (margin-inset) edge, so
        # add back its right margin, and its drawn width is `llp.xl - llp.xi`.
        # `el` self-offsets by its own left margin during render
        # (`coords`), giving adjacent flow children
        # `last.margin.right + el.margin.left` separation (additive; no CSS
        # margin-collapsing).
        #
        # When nothing rendered before `i` but the immediate predecessor *was*
        # placed (its `lpos` was nil'd this frame by scroll-clipping, not by
        # being skipped), chain off its assigned geometry instead — otherwise a
        # scrolled flow blanks entirely as every later child re-piles at (0, 0).
        # Only a genuine absence of any predecessor falls through to the origin.
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

        # Include the child's own left margin: the render pipeline
        # (`coords`) shifts the drawn box right by `mleft` without shrinking
        # a fixed width, so the child occupies [left + mleft, left + mleft +
        # awidth). Omitting it keeps a margined child whose margin box straddles
        # the right edge on the row and paints it past the interior instead of
        # wrapping.
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

      # Tallest *outer* height among the arranged children in `[from, to)` — the
      # row we're leaving — used to advance `@row_offset` on wrap. A rendered
      # child contributes its drawn rect height; a child that was placed but not
      # rendered (scroll-clipped) contributes its assigned `aheight`, both plus
      # the child's vertical margin. Without the clipped fallback the cursor
      # stalls at 0 for a fully-clipped row, re-piling every later row on top of
      # it. Scans the index range directly (no `children[from...to]` slice copy).
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
      # actually arranged and rendered to a non-empty rectangle, with that
      # rectangle. Shared by the row-tallest scan (`#flow_place`) and the
      # upward gravitation (`Masonry#gravitate_up`): skips `layout_excluded?`
      # chrome and not-yet/never-rendered children. Block-yielding, so it
      # allocates nothing per frame.
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
      # interior's bottom edge, otherwise nil. Uses the computed `aheight`
      # rather than raw `height` so a child with no explicit/nil/percent height
      # (legal here since flow children are `shrink_to_fit`) is measured instead of
      # raising on an `.as(Int)` cast.
      #
      # NOTE: for a nil/auto-height child the auto branch of `aheight` fills the
      # remaining interior *below* `el.top`, so `el.top + aheight` collapses to
      # exactly the interior height (it never exceeds it) regardless of how far
      # the child has wrapped. As a result a nil-height flow child is never
      # reported as overflowing, so `SkipWidget`/`StopRendering` cannot rely on
      # it — reliable bottom-overflow detection requires an explicit child
      # height (the vertical analogue of the explicit-width requirement flow
      # widths already carry).
      protected def overflow_action(container : Widget, el : Widget, interior : RenderedGeometry) : Overflow?
        height = interior.yl - interior.yi
        # Include the top margin: the render pipeline shifts a fixed-size box
        # down by `mtop` without shrinking it (`coords`), so its real
        # bottom edge is `top + mtop + aheight` — the vertical analogue of the
        # `mleft` term the horizontal wrap check in `#flow_place` already carries.
        # Safe for auto-height children too: their `aheight` already folds both
        # vertical margins in, so adding `mtop` still can't exceed the interior.
        if el.top.as(Int) + el.mtop + el.aheight > height
          return container.overflow
        end
        nil
      end
    end
  end
end
