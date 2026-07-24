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
        property region : Region

        def initialize(@region : Region)
        end
      end

      # Placing a child writes a resolved `Int32` back over its consume-axis
      # size, which would destroy the raw value: a `"50%"` would freeze at frame
      # 1's cell count and a transient clamp would stick. Remember each child's
      # raw size and the Int last assigned, restore the raw value before
      # re-reading `aheight`/`awidth`, and release the child once its raw size
      # no longer matches what we assigned — the user reclaimed it.
      @consume_raw = {} of Widget => (Dim | Int32 | String)?
      @consume_assigned = {} of Widget => Int32

      # Reused, cleared-not-reallocated per-region buckets: one bucketing pass
      # over the children fills these, replacing the five full `region_of`-
      # filtering scans. Within-region order is preserved (children append in
      # child order), and the edges are still processed top/bottom→left/right→
      # center by iterating the buckets in that order.
      @bucket_top = [] of Widget
      @bucket_bottom = [] of Widget
      @bucket_left = [] of Widget
      @bucket_right = [] of Widget
      @bucket_center = [] of Widget

      def arrange(container : Widget, interior : RenderedGeometry) : Nil
        # Prune bookkeeping for children that have left the container.
        prune_managed container, @consume_raw
        prune_managed container, @consume_assigned

        # Working rect in interior-local coordinates.
        x0 = 0
        y0 = 0
        x1 = interior.width
        y1 = interior.height

        # One bucketing pass over the children instead of five full
        # `region_of`-filtering scans: fill the five reused buckets in child
        # order (preserving within-region order), then process them top/bottom→
        # left/right→center below.
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
          # Center: everything not top/bottom/left/right. Consumes neither axis,
          # so it needs no release bookkeeping.
          place_and_render el, x0, y0, Math.max(0, x1 - x0 - el.mhorizontal), Math.max(0, y1 - y0 - el.mvertical)
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
          restore_consume el, vertical
          if vertical
            # Consume height off the near/far edge; span the remaining width.
            mh = el.mvertical
            ch = el.aheight.clamp(0, Math.max(0, y1 - y0 - mh))
            cw = Math.max(0, x1 - x0 - el.mhorizontal)
            place_and_render el, x0, (far ? y1 - ch - mh : y0), cw, ch
            record_managed el, @consume_assigned, ch
            far ? (y1 -= ch + mh) : (y0 += ch + mh)
          else
            # Consume width off the near/far edge; span the remaining height.
            mw = el.mhorizontal
            cw = el.awidth.clamp(0, Math.max(0, x1 - x0 - mw))
            ch = Math.max(0, y1 - y0 - el.mvertical)
            place_and_render el, (far ? x1 - cw - mw : x0), y0, cw, ch
            record_managed el, @consume_assigned, cw
            far ? (x1 -= cw + mw) : (x0 += cw + mw)
          end
        end
        {x0, y0, x1, y1}
      end

      # Restores `el`'s remembered raw consume-axis size (height when *vertical*,
      # width otherwise) before its `aheight`/`awidth` is re-read. If the raw size
      # no longer equals what was last assigned, the user reclaimed it: forget the
      # old value and honor the new one.
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
