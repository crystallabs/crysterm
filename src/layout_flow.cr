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
          # Skip `layout_chrome?` children (a border label or bound scroll bar)
          # too — like every other engine via `each_arrangeable`. They are pinned
          # at their own coordinates and painted by `#render_chrome`; arranging one
          # as flow child 0 would overwrite its pins, consume a slot, and wrap the
          # real children (BUGS15 #20, missed for the whole Flow family).
          next if el.layout_excluded? || el.layout_chrome?
          # A hidden child gives its space back (`#vacant?`), packing as though
          # it weren't there — matching `Layout::Box`/`Border`. Mirror the
          # SkipWidget path: consume its render index, nil its subtree's
          # `lpos`, and don't advance `@prev_el` — otherwise its assigned
          # extent inflates the row height, indents successors off the
          # assigned-geometry chain, and can trip the container's overflow
          # action for a widget that paints nothing.
          if vacant? el
            bump_index el
            skip_subtree el
            next
          end
          # Every child consumes a render index, even one we skip below, to
          # keep z-order bookkeeping consistent.
          bump_index el

          # Snapshot the row cursor: `place_one` may wrap this child to a new row
          # (advancing `@row_offset`/`@row_index`) before deciding it overflows
          # vertically and must be skipped. A skipped child renders nothing, so
          # leaving the cursor advanced strands every later child on the empty new
          # row while it still chains its `left` off the prior row's last rendered
          # child — the restore below un-consumes the wrap no child took.
          saved_offset, saved_index, saved_last = @row_offset, @row_index, @last_row_index

          case place_one container, el, i, interior
          when Overflow::SkipWidget
            @row_offset, @row_index, @last_row_index = saved_offset, saved_index, saved_last
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
              skip_subtree nxt unless nxt.layout_excluded? || nxt.layout_chrome?
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
        # A deferred (z-indexed) predecessor's `lpos` is only refreshed later,
        # during plane compositing, so from frame 2 on it still holds the
        # PREVIOUS frame's rect — chaining off it would lag successors one
        # frame behind any geometry change. Fall through to the assigned-
        # geometry branch instead (in steady state both compute the same left:
        # `occupied_width` reads a shrink-to-fit child's drawn width, so even
        # an auto-sized deferred predecessor chains at its real extent).
        if (last = last_rendered_before container, i) && !deferred_this_frame?(last) &&
           (llp = rendered_geometry(last))
          el.left = (llp.xl + last.mright) - xi
          last_drawn = llp.width
        elsif (last = @prev_el)
          last_drawn = occupied_width last
          el.left = last.left.as(Int) + last.mleft + last_drawn + last.mright
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
      # A `layout_suppressed?` child is excluded entirely: within one arrange pass
      # suppressed == skipped-this-frame (SkipWidget/StopRendering), and its
      # `aheight` fallback would otherwise inflate the row by a widget that never
      # renders. Scroll-clipped children stay counted — their `#_render` ran and
      # cleared the flag even though it produced no `lpos` (BUGS15 #4).
      protected def row_tallest(container : Widget, from : Int32, to : Int32) : Int32
        tallest = 0
        j = from
        while j < to
          el = container.children[j]
          unless el.layout_excluded? || el.layout_chrome? || el.layout_suppressed?
            eh =
              if !deferred_this_frame?(el) && (lp = rendered_geometry(el))
                lp.height + el.mvertical
              else
                # Placed-but-unrendered (scroll-clipped) or deferred to a plane
                # (stale `lpos`): the assigned height is the truth this frame —
                # via `occupied_height`, since a deferred shrink-to-fit child's
                # `aheight` reports the stretched remaining interior, which
                # would advance the row cursor to the container bottom.
                occupied_height(el) + el.mvertical
              end
            tallest = eh if eh > tallest
          end
          j += 1
        end
        tallest
      end

      # `el`'s occupied horizontal extent for chain/snap math. Normally the
      # assigned `awidth` — but a shrink-to-fit (nil-width) child DRAWS at its
      # shrunk content width while its `awidth` resolves to the full remaining
      # interior, so for those the drawn rect is the truth (exact in steady
      # state; one frame stale after a change, which beats a permanently
      # stretched full-interior extent). Falls back to `awidth` when no drawn
      # rect exists (frame 1, or scroll-clipped, where `lpos` is nil'd).
      private def occupied_width(el : Widget) : Int32
        if el.width.nil? && (lp = rendered_geometry(el))
          lp.width
        else
          el.awidth
        end
      end

      # :ditto: for the vertical axis (`aheight` / drawn height).
      private def occupied_height(el : Widget) : Int32
        if el.height.nil? && (lp = rendered_geometry(el))
          lp.height
        else
          el.aheight
        end
      end

      # True when `el` will be composited on its own plane this frame — the
      # exact predicate `render_or_defer` uses. Such a child's `lpos` is not
      # refreshed until plane compositing, so within `#arrange` it still holds
      # the previous frame's rect and must not anchor chain/row-height math.
      private def deferred_this_frame?(el : Widget) : Bool
        return false unless el.style.z_index
        !el.window.compositing_layers?
      end

      # Yields each child in `container.children[from...to]` that this engine
      # arranged and rendered to a non-empty rectangle, with that rectangle;
      # `layout_excluded?` chrome and unrendered children are skipped.
      # Block-yielding, so it allocates nothing per frame.
      protected def each_rendered_in_range(container : Widget, from : Int32, to : Int32, &) : Nil
        j = from
        while j < to
          el = container.children[j]
          if !el.layout_excluded? && !el.layout_chrome? && (lp = rendered_geometry(el))
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
