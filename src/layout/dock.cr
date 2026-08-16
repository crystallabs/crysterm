require "../layout"

module Crysterm
  class Layout
    # Border / dock layout (Java's `BorderLayout`, WPF's `DockPanel`). Children
    # are docked to an edge via a `Border::Hint`; the center fills whatever is
    # left. Edge children are processed top/bottom first (spanning the full
    # width), then left/right (spanning the remaining height), then center —
    # the classic five-region carve.
    #
    # ```
    # b = Widget::Box.new parent: window, width: "100%", height: "100%",
    #   layout: Layout::Dock.new
    # Widget::Box.new parent: b, height: 1,
    #   layout_hint: Layout::Dock::Hint.new(:top) # header
    # Widget::Box.new parent: b, width: 20,
    #   layout_hint: Layout::Dock::Hint.new(:left) # sidebar
    # Widget::Box.new parent: b                    # center (no hint)
    # ```
    #
    # An edge child must carry a size in the direction it consumes (a `Top`
    # child needs a `height`, a `Left` child needs a `width`); the span
    # direction is set by the layout. A child with no hint defaults to `Center`.
    #
    # <!-- widget-examples:capture v1 -->
    # ![Dock screenshot](../../tests/layout/dock/dock.5s.apng)
    # <!-- /widget-examples:capture -->
    class Dock < Layout
      enum Region
        Top
        Bottom
        Left
        Right
        Center
      end

      class Hint < Layout::Hint
        property region : Region

        # Consume-axis size override (height for `Top`/`Bottom`, width for
        # `Left`/`Right`), taking precedence over the child's own resolved
        # size. `nil` reads the child (`aheight`/`awidth`); meaningless for
        # `Center` (both axes are the remaining rect).
        property size : Int32?

        def initialize(@region : Region, @size : Int32? = nil)
        end
      end

      # Placing a child assigns *both* axes — the consume axis (from
      # `aheight`/`awidth`) and the span axis (the full remaining
      # width/height) — through the layout-geometry channel
      # (`Widget#set_layout_geometry`), so the child's own specs stay
      # untouched: a `"50%"` re-resolves every frame and a perpendicular
      # re-dock (top/bottom <-> left/right) reads true specs, never a stale
      # resolved value. The one ordering rule that remains is
      # `clear_layout_sizes` before the consume-axis `a*` read (see
      # `#consume_edge`), since `awidth`/`aheight` prefer a layout-assigned
      # value over the spec.

      # Reused, cleared-not-reallocated per-region buckets: one bucketing pass
      # over the children fills these. Within-region order is preserved
      # (children append in child order), and the edges are processed
      # top/bottom→left/right→center by iterating the buckets in that order.
      @bucket_top = [] of Widget
      @bucket_bottom = [] of Widget
      @bucket_left = [] of Widget
      @bucket_right = [] of Widget
      @bucket_center = [] of Widget

      # `#spacing`, clamped per arrange against the axis it separates bands
      # on (see `Layout#clamped_spacing`); consumed by `#consume_edge`.
      @sp_h = 0
      @sp_v = 0

      def arrange(container : Widget, interior : RenderedGeometry) : Nil
        # Working rect in interior-local coordinates.
        x0 = 0
        y0 = 0
        x1 = interior.width
        y1 = interior.height

        # Inter-band spacing: each consumed edge band advances the working
        # rect by an extra gap toward the center.
        @sp_h = clamped_spacing @spacing, x1
        @sp_v = clamped_spacing @spacing, y1

        # Fill the five reused buckets in child order, then process them
        # top/bottom→left/right→center below.
        @bucket_top.clear
        @bucket_bottom.clear
        @bucket_left.clear
        @bucket_right.clear
        @bucket_center.clear
        each_occupying container do |el|
          case region_of el
          in .top?    then @bucket_top << el
          in .bottom? then @bucket_bottom << el
          in .left?   then @bucket_left << el
          in .right?  then @bucket_right << el
          in .center? then @bucket_center << el
          end
        end

        # Each edge consumes only what the working rect has left, clamped to the
        # remaining span: without the clamp, oversized edges would overlap and
        # hand the center a negative extent.
        #
        # Regions reserve each child's *margin* box, not its border box: the
        # render pipeline shifts a fixed-size child outward by its near margin
        # without shrinking it, so advancing by size alone (or assigning the full
        # span) would paint a margined child over its neighbor.
        x0, y0, x1, y1 = consume_edge @bucket_top, :top, x0, y0, x1, y1
        x0, y0, x1, y1 = consume_edge @bucket_bottom, :bottom, x0, y0, x1, y1
        x0, y0, x1, y1 = consume_edge @bucket_left, :left, x0, y0, x1, y1
        x0, y0, x1, y1 = consume_edge @bucket_right, :right, x0, y0, x1, y1
        @bucket_center.each do |el|
          # Center: everything not top/bottom/left/right — both axes assigned
          # the remaining rect (via the layout channel; specs untouched).
          cw = margin_box(x1 - x0, el.mhorizontal)
          ch = margin_box(y1 - y0, el.mvertical)
          place_child el, x0, y0, cw, ch
          render_child el
        end
      end

      # Places every child docked to `region` and returns the working rect
      # `{x0, y0, x1, y1}` shrunk by the band they consumed — the single edge
      # pass the top/bottom/left/right calls in `#arrange` share, threaded through
      # as a tuple rather than mutating ivars so the working rect stays purely
      # local per-`arrange`-call state. Two booleans decide everything the four
      # edges differ by: `vertical` (top/bottom consume height, spanning the
      # remaining width; left/right consume width, spanning the remaining height)
      # and `far` (bottom/right eat from the far edge and place against it, top/
      # left from the near edge). Each child reserves its *margin* box, clamped to
      # what the rect has left, so an oversized edge can't hand the center a
      # negative extent.
      private def consume_edge(bucket : Array(Widget), region : Region, x0 : Int32, y0 : Int32, x1 : Int32, y1 : Int32) : Tuple(Int32, Int32, Int32, Int32)
        vertical = region.top? || region.bottom?
        far = region.bottom? || region.right?
        bucket.each do |el|
          # Both axes were layout-assigned last frame (consume + span), and the
          # consume-axis `a*` read below must resolve the child's own spec —
          # quietly drop the stale assignments first.
          clear_layout_sizes el
          if vertical
            # Consume height off the near/far edge; span the remaining width.
            mh = el.mvertical
            ch = (hint_size(el) || el.aheight).clamp(0, margin_box(y1 - y0, mh))
            cw = margin_box(x1 - x0, el.mhorizontal)
            place_child el, x0, (far ? y1 - ch - mh : y0), cw, ch
            render_child el
            # The consumed band plus the inter-band gap, clamped so spacing
            # can't invert the working rect.
            adv = Math.min(ch + mh + @sp_v, y1 - y0)
            far ? (y1 -= adv) : (y0 += adv)
          else
            # Consume width off the near/far edge; span the remaining height.
            mw = el.mhorizontal
            cw = (hint_size(el) || el.awidth).clamp(0, margin_box(x1 - x0, mw))
            ch = margin_box(y1 - y0, el.mvertical)
            place_child el, (far ? x1 - cw - mw : x0), y0, cw, ch
            render_child el
            adv = Math.min(cw + mw + @sp_h, x1 - x0)
            far ? (x1 -= adv) : (x0 += adv)
          end
        end
        {x0, y0, x1, y1}
      end

      private def region_of(el : Widget) : Region
        (el.layout_hint.as?(Hint)).try(&.region) || Region::Center
      end

      # The child's `Hint#size` consume-axis override, or nil to read the
      # child's own resolved size.
      private def hint_size(el : Widget) : Int32?
        el.layout_hint.as?(Hint).try &.size
      end
    end
  end
end
