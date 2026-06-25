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
    # b = Widget::Box.new parent: screen, width: "100%", height: "100%",
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
        # frame; iterating `container.children` once per region and filtering by
        # `region_of` (an O(1) hint read) carves the working rect in the identical
        # order with zero per-frame allocation. Children retain their relative
        # order within a region (container order), exactly as the buckets did.
        container.children.each do |el|
          next if el.layout_excluded?
          next unless region_of(el).top?
          ch = el.aheight
          el.left = x0; el.top = y0; el.width = x1 - x0; el.height = ch
          render_child el
          y0 += ch
        end
        container.children.each do |el|
          next if el.layout_excluded?
          next unless region_of(el).bottom?
          ch = el.aheight
          el.left = x0; el.top = y1 - ch; el.width = x1 - x0; el.height = ch
          render_child el
          y1 -= ch
        end
        container.children.each do |el|
          next if el.layout_excluded?
          next unless region_of(el).left?
          cw = el.awidth
          el.left = x0; el.top = y0; el.width = cw; el.height = y1 - y0
          render_child el
          x0 += cw
        end
        container.children.each do |el|
          next if el.layout_excluded?
          next unless region_of(el).right?
          cw = el.awidth
          el.left = x1 - cw; el.top = y0; el.width = cw; el.height = y1 - y0
          render_child el
          x1 -= cw
        end
        container.children.each do |el|
          next if el.layout_excluded?
          # Center is the default region: everything not top/bottom/left/right.
          r = region_of el
          next if r.top? || r.bottom? || r.left? || r.right?
          el.left = x0; el.top = y0; el.width = x1 - x0; el.height = y1 - y0
          render_child el
        end
      end

      private def region_of(el : Widget) : Region
        (el.layout_hint.as?(Hint)).try(&.region) || Region::Center
      end
    end
  end
end
