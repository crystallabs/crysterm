require "../layout"

module Crysterm
  class Layout
    # Border / dock layout (Java's `BorderLayout`, WPF's `DockPanel`). Children
    # are docked to an edge via a `Border::Hint`; the center fills whatever is
    # left. Edge children are processed top/bottom first (spanning the full
    # width), then left/right (spanning the remaining height), then center —
    # the classic five-region carve. Used for TUI chrome: header, footer,
    # sidebars, main pane.
    #
    # ```
    # b = Widget::Box.new parent: window, width: "100%", height: "100%",
    #   layout: Layout::Border.new
    # Widget::Box.new parent: b, height: 1,
    #   layout_hint: Layout::Border::Hint.new(:top) # header
    # Widget::Box.new parent: b, width: 20,
    #   layout_hint: Layout::Border::Hint.new(:left) # sidebar
    # Widget::Box.new parent: b                      # center (no hint)
    # ```
    #
    # An edge child must carry a size in the direction it consumes (a `Top`
    # child needs a `height`, a `Left` child needs a `width`); the span
    # direction is set by the layout. A child with no hint defaults to `Center`.
    #
    # <!-- widget-examples:capture v1 -->
    # ![Border screenshot](../../tests/layout/border/border.5s.apng)
    # <!-- /widget-examples:capture -->
    class Border < Layout
      enum Region
        Top
        Bottom
        Left
        Right
        Center
      end

      class Hint < Layout::Hint
        getter region : Region

        def initialize(@region : Region)
        end
      end

      # An edge child sizes itself along the direction it consumes (height for
      # Top/Bottom, width for Left/Right). Border resolves that raw size to
      # cells (`aheight`/`awidth`), clamps it to the remaining span, and writes
      # the resolved `Int32` back via `place_and_render` -> `set_geometry`. That
      # write would otherwise *destroy* the child's original value — a `"50%"`
      # string never resolves again (frozen at frame 1's cell count), and a
      # transient clamp (container briefly shrunk) becomes permanent. Mirror
      # `Layout::Box`'s `@flex_size` release bookkeeping: remember each child's
      # raw consume-axis value and the Int we last assigned; restore the raw
      # value before re-reading `aheight`/`awidth` (so a percent resolves
      # against the *live* container every frame), and release the child the
      # moment its raw size no longer matches — the user reclaimed it.
      @consume_raw = {} of Widget => (Int32 | String | Nil)
      @consume_assigned = {} of Widget => Int32

      def arrange(container : Widget, interior : LPos) : Nil
        # Prune bookkeeping for children that have left the container (O(1)
        # `child?` membership, as `Layout::Box#measure` does).
        prune_managed container, @consume_raw
        prune_managed container, @consume_assigned

        # Working rect in interior-local coordinates.
        x0 = 0
        y0 = 0
        x1 = interior.xl - interior.xi
        y1 = interior.yl - interior.yi

        # Five region passes directly over the live child array (filtering by
        # `region_of`, an O(1) hint read) instead of bucketing into five
        # `Array(Widget)` per frame; children keep their relative order within
        # a region. Each edge consumes only what the working rect has left
        # (`#aheight`/`#awidth` clamped to the remaining span) — without the
        # clamp, edges whose sizes together exceed the interior would
        # overlap and hand the center a negative width/height. Clamping keeps
        # every region non-negative and non-overlapping, collapsing squeezed-out
        # ones to zero instead. No-op when the edges fit.
        # Reserve each edge child's margin box, not just its border box: the
        # render pipeline (`_get_coords`) shifts a fixed-size child outward by its
        # near margin without shrinking it, so a top child with `margin top: N` is
        # drawn N rows below its assigned `y0`. Advancing the working rect by the
        # child's height alone would let that shifted box overlap the neighboring
        # region; advancing by `size + margin` (mirroring `Layout::Box`) keeps
        # every region non-overlapping.
        # Each edge assigns the child its full working extent along the *span*
        # axis minus that child's span-axis margins (`x1 - x0 - mwidth` for a
        # Top/Bottom bar, `y1 - y0 - mheight` for a Left/Right rail), mirroring
        # `Layout::Box`'s cross-axis handling: the render pipeline shifts a
        # fixed-size box out by its near margin *without* shrinking it, so
        # assigning the full span would paint a margined child past the region's
        # far edge (and, under the default `Overflow::Ignore`, past the
        # container). Reserving the margins keeps it inside.
        each_arrangeable container do |el|
          next unless region_of(el).top?
          restore_consume el, true
          mh = el.mheight
          ch = el.aheight.clamp(0, Math.max(0, y1 - y0 - mh))
          place_and_render el, x0, y0, Math.max(0, x1 - x0 - el.mwidth), ch
          record_managed el, @consume_assigned, ch
          y0 += ch + mh
        end
        each_arrangeable container do |el|
          next unless region_of(el).bottom?
          restore_consume el, true
          mh = el.mheight
          ch = el.aheight.clamp(0, Math.max(0, y1 - y0 - mh))
          place_and_render el, x0, y1 - ch - mh, Math.max(0, x1 - x0 - el.mwidth), ch
          record_managed el, @consume_assigned, ch
          y1 -= ch + mh
        end
        each_arrangeable container do |el|
          next unless region_of(el).left?
          restore_consume el, false
          mw = el.mwidth
          cw = el.awidth.clamp(0, Math.max(0, x1 - x0 - mw))
          place_and_render el, x0, y0, cw, Math.max(0, y1 - y0 - el.mheight)
          record_managed el, @consume_assigned, cw
          x0 += cw + mw
        end
        each_arrangeable container do |el|
          next unless region_of(el).right?
          restore_consume el, false
          mw = el.mwidth
          cw = el.awidth.clamp(0, Math.max(0, x1 - x0 - mw))
          place_and_render el, x1 - cw - mw, y0, cw, Math.max(0, y1 - y0 - el.mheight)
          record_managed el, @consume_assigned, cw
          x1 -= cw + mw
        end
        each_arrangeable container do |el|
          # Center: everything not top/bottom/left/right. It consumes neither
          # axis (fills what's left), so it needs no release bookkeeping — but it
          # still reserves both of its own margins, like the edges.
          r = region_of el
          next if r.top? || r.bottom? || r.left? || r.right?
          place_and_render el, x0, y0, Math.max(0, x1 - x0 - el.mwidth), Math.max(0, y1 - y0 - el.mheight)
        end
      end

      # Restores `el`'s remembered raw consume-axis size (height when
      # *vertical*, width otherwise) before we re-read its resolved
      # `aheight`/`awidth`, so a percent size resolves against the live
      # container every frame and a transient clamp doesn't stick. If the raw
      # size no longer equals what we last assigned, the user reclaimed it:
      # forget the old value and honor the new one (cf. `Box#main_flex?`).
      private def restore_consume(el : Widget, vertical : Bool) : Nil
        restore_managed(el, @consume_raw, @consume_assigned, vertical ? el.height : el.width) do |v|
          vertical ? (el.height = v) : (el.width = v)
        end
      end

      private def region_of(el : Widget) : Region
        (el.layout_hint.as?(Hint)).try(&.region) || Region::Center
      end
    end
  end
end
