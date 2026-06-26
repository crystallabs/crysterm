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
    # ![Form screenshot](../../examples/layout/form/form-capture5s.apng)
    # <!-- /widget-examples:capture -->
    class Form < Layout
      # Width of the (left) label column.
      property label_width : Int32
      # Horizontal gap between label and field (`#gap` is inherited from `Layout`).
      # Vertical gap between rows.
      property row_gap : Int32

      def initialize(@label_width : Int32 = 12, @gap : Int32 = 1, @row_gap : Int32 = 0)
      end

      def arrange(container : Widget, interior : LPos) : Nil
        w = interior.xl - interior.xi
        lw = Math.min(@label_width, w)
        fw = w - lw - @gap
        fw = 0 if fw < 0

        # Pair only the children this engine arranges; layout-excluded chrome
        # (e.g. a `background-image` layer) must not be consumed as a
        # label/field slot — matching every other engine's `layout_excluded?`
        # skip.
        children = container.children.reject &.layout_excluded?
        y = 0
        i = 0
        while i < children.size
          label = children[i]
          if field = children[i + 1]?
            rh = Math.max(row_height(label), row_height(field))
            label.left = 0; label.top = y; label.width = lw; label.height = rh
            field.left = lw + @gap; field.top = y; field.width = fw; field.height = rh
            render_child label
            render_child field
            y += rh + @row_gap
            i += 2
          else
            # Trailing odd child spans the full width.
            rh = row_height label
            label.left = 0; label.top = y; label.width = w; label.height = rh
            render_child label
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
