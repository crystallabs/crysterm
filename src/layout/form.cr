require "../layout"

module Crysterm
  class Layout
    # Two-column form layout (Qt's `QFormLayout`). Children are consumed in
    # pairs — a label and its field — one pair per row: the label occupies a
    # fixed `label_width` column, the field fills the rest. A trailing unpaired
    # child spans the full width (handy for a button row or separator).
    #
    # Row height is each child's explicit height, or 1 (forms are line-oriented),
    # so labels and single-line inputs line up.
    #
    # <!-- widget-examples:capture v1 -->
    # ![Form screenshot](../../tests/layout/form/form.5s.apng)
    # <!-- /widget-examples:capture -->
    class Form < Layout
      # Width of the (left) label column.
      property label_width : Int32

      # Horizontal gap between a row's label and its field, in cells. Named for
      # symmetry with `#row_gap`; the inherited `Layout#gap` is unused here.
      property column_gap : Int32

      # Vertical gap between rows, in cells.
      property row_gap : Int32

      # Reused list of arranged children, refilled each frame instead of
      # allocating a `reject` array per render.
      @row_children = [] of Widget

      # Placing a child writes the resolved row height back over its raw
      # `@height`, which would freeze a `"30%"`/`nil` height at frame 1's cells
      # and make the shared pair-row max sticky. Remember each child's raw height
      # and the Int last assigned, restore the raw value before re-measuring, and
      # release a child whose raw height the user changed.
      @raw_height = {} of Widget => (Int32 | String | Nil)
      @assigned = {} of Widget => Int32

      def initialize(@label_width : Int32 = 12, @column_gap : Int32 = 1, @row_gap : Int32 = 0)
      end

      def arrange(container : Widget, interior : RenderedGeometry) : Nil
        w = interior.xl - interior.xi
        lw = Math.min(@label_width, w)
        fw = w - lw - @column_gap
        fw = 0 if fw < 0

        # Prune bookkeeping for children no longer in the container.
        prune_managed container, @raw_height
        prune_managed container, @assigned

        # Only pair arrangeable children: layout-excluded chrome must not be
        # consumed as a label/field slot.
        children = @row_children
        children.clear
        each_arrangeable(container) { |el| children << el }
        y = 0
        i = 0
        while i < children.size
          label = children[i]
          restore_height label
          if field = children[i + 1]?
            restore_height field
            rh = Math.max(row_height(label), row_height(field))
            place_child label, 0, y, lw, rh
            place_child field, lw + @column_gap, y, fw, rh
            record_managed label, @assigned, rh
            record_managed field, @assigned, rh
            render_child label
            render_child field
            y += rh + @row_gap
            i += 2
          else
            # Trailing odd child spans the full width.
            rh = row_height label
            place_and_render label, 0, y, w, rh
            record_managed label, @assigned, rh
            y += rh + @row_gap
            i += 1
          end
        end
      end

      # A child's row height: an explicit `Int32`, a resolved `String` (e.g.
      # `"30%"` -> its `aheight` against the live container), or 1 (forms are
      # single-line by default) for a nil/auto height.
      private def row_height(el : Widget) : Int32
        case h = el.height
        when Int32  then h
        when String then el.aheight
        else             1
        end
      end

      # Restores `el`'s remembered raw height before it is re-measured. Releases
      # the child when its raw height no longer matches what was last assigned.
      private def restore_height(el : Widget) : Nil
        restore_managed(el, @raw_height, @assigned, el.height) { |v| el.height = v }
      end
    end
  end
end
