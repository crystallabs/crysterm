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
      # Width of the (left) label column, or `nil` to auto-measure the widest
      # label's content each arrange. Change-guarded so a real change repaints.
      layout_property label_width, Int32?

      # Horizontal gap between a row's label and its field, in cells. Named for
      # symmetry with `#vertical_spacing`; the inherited `Layout#spacing` is
      # unused here. Change-guarded so a real change repaints.
      layout_property horizontal_spacing, Int32

      # Vertical gap between rows, in cells. Change-guarded so a real change
      # repaints.
      layout_property vertical_spacing, Int32

      # Reused list of arranged children, refilled each frame instead of
      # allocating a `reject` array per render.
      @row_children = [] of Widget

      # Placing a child writes the resolved row height back over its raw
      # `@height`, which would freeze a `"30%"`/`nil` height at frame 1's cells
      # and make the shared pair-row max sticky. Remember each child's raw height
      # and the Int last assigned, restore the raw value before re-measuring, and
      # release a child whose raw height the user changed.
      @raw_height = {} of Widget => (Dim | Int32 | String)?
      @assigned = {} of Widget => Int32

      # Placing a child likewise writes the resolved column width back over its
      # raw `@width`, which would freeze an auto (`nil`)/`"50%"` width at frame
      # 1's cells and — worse — make the auto label column sticky, since
      # `measured_label_width` reads back the assigned Int as if it were an
      # explicit width. Same raw/assigned bookkeeping as height, but restored
      # *before* the placement loop: label widths are read up front by
      # `label_column_width`, so restoring inside the loop would be too late.
      @raw_width = {} of Widget => (Dim | Int32 | String)?
      @assigned_width = {} of Widget => Int32

      def initialize(@label_width : Int32? = nil, @horizontal_spacing : Int32 = 1, @vertical_spacing : Int32 = 0)
      end

      def arrange(container : Widget, interior : RenderedGeometry) : Nil
        w = interior.width

        # Clamp both spacings against the live interior before they enter the
        # checked arithmetic below (`lw + hs`, `y += ... + vs`): a raw
        # `Int32::MAX` overflows and a negative overlaps columns/rows. Beyond
        # the interior there is no room for the other column / next row anyway,
        # so clamping loses nothing for sane values.
        hs = clamped_spacing @horizontal_spacing, w
        vs = clamped_spacing @vertical_spacing, interior.height

        # Prune bookkeeping for children no longer in the container.
        prune_managed container, @raw_height
        prune_managed container, @assigned
        prune_managed container, @raw_width
        prune_managed container, @assigned_width

        # Only pair arrangeable children: layout-excluded chrome must not be
        # consumed as a label/field slot.
        children = @row_children
        children.clear
        each_arrangeable(container) { |el| children << el }

        # Restore each child's raw width before it is measured/placed, so an
        # auto/percent width re-resolves and a layout-assigned Int never leaks
        # into the next frame's `label_column_width`.
        children.each { |el| restore_width el }

        # Label column width: the fixed `#label_width`, or the widest paired
        # label's own content when auto (`nil`). Clamped to the interior width.
        lw = Math.min(label_column_width(children), w)
        fw = w - lw - hs
        fw = 0 if fw < 0

        y = 0
        i = 0
        while i < children.size
          label = children[i]
          restore_height label
          if field = children[i + 1]?
            restore_height field
            # Shared content row height, so the label and field align. Each
            # child's assigned width reserves its own horizontal margin box:
            # `_get_coords` shifts a fixed-size box outward by its near margin
            # without shrinking it, so a raw-`lw`/`fw` child would paint its
            # margin past its column into the neighbouring one. Mirror
            # Layout::Box's margin-box reservation.
            # Clamp the row height to the interior before it enters the checked
            # `y += ...` cursor accumulation: an `Int32::MAX`-height child would
            # otherwise overflow the sum. Beyond the interior "fills
            # everything visible", so clamping loses nothing.
            rh = clamped_size(Math.max(row_height(label), row_height(field)), interior.height)
            lc = margin_box lw, label.mhorizontal
            fc = margin_box fw, field.mhorizontal
            place_recorded label, 0, y, lc, rh, @assigned_width, @assigned
            place_recorded field, lw + hs, y, fc, rh, @assigned_width, @assigned
            render_child label
            render_child field
            # Advance by the tallest margin box on the row so a margined child
            # doesn't bleed down into the next row's slot.
            y += Math.max(rh + label.mvertical, rh + field.mvertical) + vs
            i += 2
          else
            # Trailing odd child spans the full width, less its margin box.
            rh = clamped_size(row_height(label), interior.height)
            lc = margin_box w, label.mhorizontal
            place_recorded label, 0, y, lc, rh, @assigned_width, @assigned
            render_child label
            y += rh + label.mvertical + vs
            i += 1
          end
        end
      end

      # Adds a labeled field row through the `#container` back-pointer: creates a
      # lightweight label `Box` (as the two-by-two pair consumption expects), then
      # appends *label* and *field* as a fresh pair, and returns *field*. Raises
      # when the layout isn't installed on a container yet.
      def add_row(label : String, field : Widget) : Widget
        c = require_container "Layout::Form#add_row"
        label_box = Widget::Box.new height: 1, content: label
        append_row c, label_box, field
        field
      end

      # `Widget` overload of `#add_row`: pairs an already-built *label* widget
      # with *field* instead of wrapping a `String` in a fresh `Box` — for a
      # custom label (an icon + text box, a styled heading, ...). Same
      # insert-before-trailing placement as the `String` overload.
      def add_row(label : Widget, field : Widget) : Widget
        c = require_container "Layout::Form#add_row"
        append_row c, label, field
        field
      end

      # Full-span overload: adds *w* as a trailing, unpaired row spanning the
      # whole width — Qt's `QFormLayout::addRow(QWidget*)`. Reuses the same
      # insert-before-trailing placement, so a full-span row added after
      # another one doesn't get paired into a label/field row.
      def add_row(w : Widget) : Widget
        c = require_container "Layout::Form#add_row"
        append_row c, w
        w
      end

      # Appends *widgets* as a fresh trailing group. Pairing (and full-span
      # placement) is positional over the *arrangeable* children: when the
      # form currently ends with a blessed trailing odd child (a
      # separator/button row), a plain append would fold the new group into
      # it — a paired label would be consumed as that child's "field", or a
      # new full-span child would land after it instead of taking its slot.
      # Insert the group BEFORE the trailing child so it stays trailing —
      # appending a filler instead would pull the separator into the label
      # column, destroying its documented full-width span.
      private def append_row(c : Widget, *widgets : Widget) : Nil
        count = 0
        trailing = nil.as(Widget?)
        each_arrangeable(c) do |el|
          count += 1
          trailing = el
        end
        if count.odd? && (t = trailing)
          widgets.each { |w| c.insert_before w, t }
        else
          widgets.each { |w| c.append w }
        end
      end

      # The label column width: the fixed `#label_width` when set, else the widest
      # *paired* label's measured content width (auto). Fields (odd children) and a
      # trailing full-width child don't count toward the auto width.
      private def label_column_width(children : Array(Widget)) : Int32
        if lw = @label_width
          return lw
        end
        widest = 0
        pairs = false
        i = 0
        while i < children.size
          # Only a label that actually has a following field forms a pair.
          if children[i + 1]?
            pairs = true
            m = measured_label_width children[i]
            widest = m if m > widest
          end
          i += 2
        end
        # Floor at one cell when pairs exist: a label with no measurable width
        # yet (content unprocessed, or a content-less placeholder) must still
        # occupy its slot, or it renders nowhere (`lpos` nil).
        pairs ? Math.max(widest, 1) : widest
      end

      # A label's intrinsic content width: an explicit `Int32` width wins;
      # otherwise the widest wrapped line plus the label's own horizontal
      # insets (border/padding), so a bordered label still fits.
      private def measured_label_width(el : Widget) : Int32
        if (w = el.width).is_a?(Int32)
          return w
        end
        el._clines.max_width + el.ihorizontal
      end

      # A child's row height: an explicit `Int32`, a resolved `Dim`/`String`
      # (e.g. `"30%"` -> its `aheight` against the live container), or 1
      # (forms are single-line by default) for a nil/auto height.
      private def row_height(el : Widget) : Int32
        case h = el.height
        when Int32       then h
        when Dim, String then el.aheight
        else                  1
        end
      end

      # Restores `el`'s remembered raw height before it is re-measured. Releases
      # the child when its raw height no longer matches what was last assigned.
      private def restore_height(el : Widget) : Nil
        restore_managed(el, @raw_height, @assigned, el.height) { |v| el.height = v }
      end

      # Restores `el`'s remembered raw width before it is re-measured/placed.
      # Releases the child when its raw width no longer matches what was last
      # assigned (the user set an explicit width).
      private def restore_width(el : Widget) : Nil
        restore_managed(el, @raw_width, @assigned_width, el.width) { |v| el.width = v }
      end
    end
  end
end
