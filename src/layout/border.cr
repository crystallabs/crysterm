require "../layout"

module Crysterm
  class Layout
    # Border / dock layout (Java's `BorderLayout`, WPF's `DockPanel`). Children
    # are docked to an edge via a `Border::Hint`; the center fills whatever is
    # left. Edge children are processed top/bottom first (spanning the full
    # width), then left/right (spanning the remaining height), then center —
    # exactly the classic five-region carve. The mainstay of TUI chrome: header,
    # footer, sidebars, main pane.
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
    # ![Border screenshot](../../examples/layout/border/border-capture5s.apng)
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

        # Five region passes directly over the live child array. The earlier
        # version bucketed children into five `Array(Widget)` allocated every
        # frame; iterating the arrangeable children once per region and filtering
        # by `region_of` (an O(1) hint read) carves the working rect in the
        # identical order with zero per-frame allocation. Children retain their
        # relative order within a region (container order), exactly as the buckets
        # did. Each edge consumes only what the working rect still has left
        # (`#aheight`/`#awidth` clamped to the remaining span). Without the clamp,
        # edges whose sizes together exceed the interior — e.g. a header and footer
        # taller than the box — over-consumed the rect: the second edge of a pair
        # overlapped the first (its `y1 - ch` / `x1 - cw` ran back into the
        # already-placed region), and the cross-spanning edges and the center were
        # then handed a *negative* `y1 - y0` / `x1 - x0` as their height/width.
        # Clamping each edge to the live remainder keeps every region non-negative
        # and non-overlapping, collapsing the squeezed-out ones to zero (the
        # standard "container too small" degradation) instead. The clamp is a no-op
        # whenever the edges fit, so well-sized layouts are unaffected.
        each_arrangeable container do |el|
          next unless region_of(el).top?
          ch = el.aheight.clamp(0, y1 - y0)
          place_and_render el, x0, y0, x1 - x0, ch
          y0 += ch
        end
        each_arrangeable container do |el|
          next unless region_of(el).bottom?
          ch = el.aheight.clamp(0, y1 - y0)
          place_and_render el, x0, y1 - ch, x1 - x0, ch
          y1 -= ch
        end
        each_arrangeable container do |el|
          next unless region_of(el).left?
          cw = el.awidth.clamp(0, x1 - x0)
          place_and_render el, x0, y0, cw, y1 - y0
          x0 += cw
        end
        each_arrangeable container do |el|
          next unless region_of(el).right?
          cw = el.awidth.clamp(0, x1 - x0)
          place_and_render el, x1 - cw, y0, cw, y1 - y0
          x1 -= cw
        end
        each_arrangeable container do |el|
          # Center is the default region: everything not top/bottom/left/right.
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
