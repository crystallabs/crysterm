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

      # Placing a child writes a resolved `Int32` back over *both* axes — the
      # consume axis (from `aheight`/`awidth`) and the span axis (the full
      # remaining width/height) — which would destroy the raw values: a `"50%"`
      # would freeze at frame 1's cell count, a transient clamp would stick,
      # and (the bug this guards against) re-docking a child to a perpendicular
      # region would read the OTHER axis's stale resolved value as if it were
      # the new consume axis's raw size. Bookkeeping is therefore axis-keyed,
      # not role-keyed (consume/span flips per region, per child, per re-dock):
      # a width pair and a height pair, each restored and recorded for every
      # managed child (edge *and* center) every frame, exactly mirroring
      # `Layout::Form`'s `@raw_width`/`@raw_height` split.
      @raw_width = {} of Widget => (Dim | Int32 | String)?
      @assigned_width = {} of Widget => Int32
      @raw_height = {} of Widget => (Dim | Int32 | String)?
      @assigned_height = {} of Widget => Int32

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
        prune_managed container, @raw_width
        prune_managed container, @assigned_width
        prune_managed container, @raw_height
        prune_managed container, @assigned_height

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
          # Center: everything not top/bottom/left/right. Consumes neither axis
          # by name, but still has its raw width/height overwritten with a
          # resolved full-span Int32 every frame, so it needs the same
          # restore/record bookkeeping as the edges (e.g. a center child later
          # re-hinted to an edge must not inherit a poisoned span size).
          restore_size el
          cw = margin_box(x1 - x0, el.mhorizontal)
          ch = margin_box(y1 - y0, el.mvertical)
          place_recorded el, x0, y0, cw, ch, @assigned_width, @assigned_height
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
          restore_size el
          if vertical
            # Consume height off the near/far edge; span the remaining width.
            mh = el.mvertical
            ch = el.aheight.clamp(0, margin_box(y1 - y0, mh))
            cw = margin_box(x1 - x0, el.mhorizontal)
            place_recorded el, x0, (far ? y1 - ch - mh : y0), cw, ch, @assigned_width, @assigned_height
            render_child el
            far ? (y1 -= ch + mh) : (y0 += ch + mh)
          else
            # Consume width off the near/far edge; span the remaining height.
            mw = el.mhorizontal
            cw = el.awidth.clamp(0, margin_box(x1 - x0, mw))
            ch = margin_box(y1 - y0, el.mvertical)
            place_recorded el, (far ? x1 - cw - mw : x0), y0, cw, ch, @assigned_width, @assigned_height
            render_child el
            far ? (x1 -= cw + mw) : (x0 += cw + mw)
          end
        end
        {x0, y0, x1, y1}
      end

      # Restores `el`'s remembered raw width AND height before either
      # `aheight`/`awidth` is re-read. Both axes get overwritten with a
      # resolved `Int32` every frame regardless of which one the child's
      # current region *consumes* — the other axis gets the full span — so
      # both must be restored/tracked independently or a perpendicular
      # re-dock (top/bottom <-> left/right) reads the wrong axis's stale
      # resolved value as its "raw" size. Per axis: if the raw size no longer
      # equals what was last assigned, the user reclaimed it — forget the old
      # value and honor the new one.
      private def restore_size(el : Widget) : Nil
        restore_managed(el, @raw_width, @assigned_width, el.width) { |v| el.width = v }
        restore_managed(el, @raw_height, @assigned_height, el.height) { |v| el.height = v }
      end

      private def region_of(el : Widget) : Region
        (el.layout_hint.as?(Hint)).try(&.region) || Region::Center
      end
    end
  end
end
