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
      @consume_raw = {} of Widget => (Dim | Int32 | String | Nil)
      @consume_assigned = {} of Widget => Int32

      def arrange(container : Widget, interior : RenderedGeometry) : Nil
        # Prune bookkeeping for children that have left the container.
        prune_managed container, @consume_raw
        prune_managed container, @consume_assigned

        # Working rect in interior-local coordinates.
        x0 = 0
        y0 = 0
        x1 = interior.width
        y1 = interior.height

        # Five passes filter the live child array by `region_of` rather than
        # bucketing into five `Array(Widget)` per frame; children keep their
        # relative order within a region.
        #
        # Each edge consumes only what the working rect has left, clamped to the
        # remaining span: without the clamp, oversized edges would overlap and
        # hand the center a negative extent.
        #
        # Regions reserve each child's *margin* box, not its border box: the
        # render pipeline shifts a fixed-size child outward by its near margin
        # without shrinking it, so advancing by size alone (or assigning the full
        # span) would paint a margined child over its neighbor.
        each_arrangeable container do |el|
          next unless region_of(el).top?
          # Hidden and not holding its slot: consume no band.
          next if vacant? el
          restore_consume el, true
          mh = el.mvertical
          ch = el.aheight.clamp(0, Math.max(0, y1 - y0 - mh))
          place_and_render el, x0, y0, Math.max(0, x1 - x0 - el.mhorizontal), ch
          record_managed el, @consume_assigned, ch
          y0 += ch + mh
        end
        each_arrangeable container do |el|
          next unless region_of(el).bottom?
          # Hidden and not holding its slot: consume no band.
          next if vacant? el
          restore_consume el, true
          mh = el.mvertical
          ch = el.aheight.clamp(0, Math.max(0, y1 - y0 - mh))
          place_and_render el, x0, y1 - ch - mh, Math.max(0, x1 - x0 - el.mhorizontal), ch
          record_managed el, @consume_assigned, ch
          y1 -= ch + mh
        end
        each_arrangeable container do |el|
          next unless region_of(el).left?
          # Hidden and not holding its slot: consume no band.
          next if vacant? el
          restore_consume el, false
          mw = el.mhorizontal
          cw = el.awidth.clamp(0, Math.max(0, x1 - x0 - mw))
          place_and_render el, x0, y0, cw, Math.max(0, y1 - y0 - el.mvertical)
          record_managed el, @consume_assigned, cw
          x0 += cw + mw
        end
        each_arrangeable container do |el|
          next unless region_of(el).right?
          # Hidden and not holding its slot: consume no band.
          next if vacant? el
          restore_consume el, false
          mw = el.mhorizontal
          cw = el.awidth.clamp(0, Math.max(0, x1 - x0 - mw))
          place_and_render el, x1 - cw - mw, y0, cw, Math.max(0, y1 - y0 - el.mvertical)
          record_managed el, @consume_assigned, cw
          x1 -= cw + mw
        end
        each_arrangeable container do |el|
          # Center: everything not top/bottom/left/right. Consumes neither axis,
          # so it needs no release bookkeeping.
          r = region_of el
          next if r.top? || r.bottom? || r.left? || r.right?
          next if vacant? el
          place_and_render el, x0, y0, Math.max(0, x1 - x0 - el.mhorizontal), Math.max(0, y1 - y0 - el.mvertical)
        end
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
