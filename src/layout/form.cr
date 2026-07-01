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
      # Horizontal gap between label and field (`#gap` is inherited from `Layout`).
      # Vertical gap between rows.
      property row_gap : Int32

      # Reused list of arranged children, refilled each frame instead of
      # allocating a `reject` array per render.
      @row_children = [] of Widget

      def initialize(@label_width : Int32 = 12, @gap : Int32 = 1, @row_gap : Int32 = 0)
      end

      def arrange(container : Widget, interior : LPos) : Nil
        w = interior.xl - interior.xi
        lw = Math.min(@label_width, w)
        fw = w - lw - @gap
        fw = 0 if fw < 0

        # Only pair arrangeable children (see `#each_arrangeable`); layout-excluded
        # chrome must not be consumed as a label/field slot.
        children = @row_children
        children.clear
        each_arrangeable(container) { |el| children << el }
        y = 0
        i = 0
        while i < children.size
          label = children[i]
          if field = children[i + 1]?
            rh = Math.max(row_height(label), row_height(field))
            place_child label, 0, y, lw, rh
            place_child field, lw + @gap, y, fw, rh
            render_child label
            render_child field
            y += rh + @row_gap
            i += 2
          else
            # Trailing odd child spans the full width.
            rh = row_height label
            place_and_render label, 0, y, w, rh
            y += rh + @row_gap
            i += 1
          end
        end
      end

      # A child's explicit height, or 1 (forms are single-line by default).
      private def row_height(el : Widget) : Int32
        (h = el.height).is_a?(Int32) ? h : 1
      end
    end
  end
end
