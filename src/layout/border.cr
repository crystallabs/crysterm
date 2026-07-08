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

      def arrange(container : Widget, interior : LPos) : Nil
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
        each_arrangeable container do |el|
          next unless region_of(el).top?
          mh = el.mheight
          ch = el.aheight.clamp(0, Math.max(0, y1 - y0 - mh))
          place_and_render el, x0, y0, x1 - x0, ch
          y0 += ch + mh
        end
        each_arrangeable container do |el|
          next unless region_of(el).bottom?
          mh = el.mheight
          ch = el.aheight.clamp(0, Math.max(0, y1 - y0 - mh))
          place_and_render el, x0, y1 - ch, x1 - x0, ch
          y1 -= ch + mh
        end
        each_arrangeable container do |el|
          next unless region_of(el).left?
          mw = el.mwidth
          cw = el.awidth.clamp(0, Math.max(0, x1 - x0 - mw))
          place_and_render el, x0, y0, cw, y1 - y0
          x0 += cw + mw
        end
        each_arrangeable container do |el|
          next unless region_of(el).right?
          mw = el.mwidth
          cw = el.awidth.clamp(0, Math.max(0, x1 - x0 - mw))
          place_and_render el, x1 - cw, y0, cw, y1 - y0
          x1 -= cw + mw
        end
        each_arrangeable container do |el|
          # Center: everything not top/bottom/left/right.
          r = region_of el
          next if r.top? || r.bottom? || r.left? || r.right?
          place_and_render el, x0, y0, x1 - x0, y1 - y0
        end
      end

      private def region_of(el : Widget) : Region
        (el.layout_hint.as?(Hint)).try(&.region) || Region::Center
      end
    end
  end
end
