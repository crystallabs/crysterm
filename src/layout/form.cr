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

      # `place_child` -> `set_geometry` writes the resolved row height back into
      # each child's raw `@height`, which would destroy a `"30%"`/`nil` height
      # (frozen forever at frame 1's resolved cells) and make the shared
      # pair-row max sticky (a field next to a taller label keeps the max even
      # after the label shrinks). Mirror `Layout::Border`'s release bookkeeping:
      # remember each child's raw height and the Int we last assigned, restore
      # the raw value before re-measuring, and release a child whose raw height
      # the user changed out from under us.
      @raw_height = {} of Widget => (Int32 | String | Nil)
      @assigned = {} of Widget => Int32

      def initialize(@label_width : Int32 = 12, @gap : Int32 = 1, @row_gap : Int32 = 0)
      end

      def arrange(container : Widget, interior : LPos) : Nil
        w = interior.xl - interior.xi
        lw = Math.min(@label_width, w)
        fw = w - lw - @gap
        fw = 0 if fw < 0

        # Prune bookkeeping for children no longer in the container.
        @raw_height.select! { |el, _| container.child? el }
        @assigned.select! { |el, _| container.child? el }

        # Only pair arrangeable children (see `#each_arrangeable`); layout-excluded
        # chrome must not be consumed as a label/field slot.
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
            place_child field, lw + @gap, y, fw, rh
            record_height label, rh
            record_height field, rh
            render_child label
            render_child field
            y += rh + @row_gap
            i += 2
          else
            # Trailing odd child spans the full width.
            rh = row_height label
            place_and_render label, 0, y, w, rh
            record_height label, rh
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

      # Restores `el`'s remembered raw height before we re-measure it, so a
      # percent/nil height survives the `set_geometry` write-back every frame
      # and the pair-row max never stays stuck. Releases the child when its raw
      # height no longer matches what we last assigned (the user set it).
      private def restore_height(el : Widget) : Nil
        raw = el.height
        if (assigned = @assigned[el]?) && raw == assigned && @raw_height.has_key?(el)
          el.height = @raw_height[el]
        else
          @raw_height[el] = raw
        end
      end

      # Remembers the row height just written into `el`, so the next frame can
      # tell a layout-owned height from a user-reclaimed one.
      private def record_height(el : Widget, v : Int32) : Nil
        @assigned[el] = v
      end
    end
  end
end
