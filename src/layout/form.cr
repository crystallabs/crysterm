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

      # Placement goes through the layout-geometry channel
      # (`Widget#set_layout_geometry`), so the children's own `width`/`height`
      # specs stay untouched: `measured_label_width` always reads a true spec
      # (the auto label column can't go sticky), and a `"30%"` row height
      # re-resolves every frame. Two ordering rules remain, both "clear the
      # stale layout assignment before resolving through it": widths before
      # the label scan (content re-wraps at the effective width), heights
      # before `#row_height` resolves a `Dim` spec via `aheight`.

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

        # Only pair arrangeable children: layout-excluded chrome must not be
        # consumed as a label/field slot.
        children = @row_children
        children.clear
        each_arrangeable(container) { |el| children << el }

        # Quietly drop last frame's assigned column widths before the label
        # scan: `measured_label_width` measures a label's *wrapped* content
        # (`_clines`), which re-wraps at the effective width — a stale layout
        # width from the previous arrange would wrap the content to the old
        # column and freeze the auto column at it. The layout-channel analogue
        # of the old restore-before-the-loop.
        children.each &.clear_layout_width

        # Label column width: the fixed `#label_width`, or the widest paired
        # label's own content when auto (`nil`). Clamped to the interior width.
        lw = Math.min(label_column_width(children), w)
        fw = w - lw - hs
        fw = 0 if fw < 0

        y = 0
        i = 0
        while i < children.size
          label = children[i]
          # `#row_height` resolves a `Dim` spec through `aheight`, which
          # prefers a layout-assigned height — quietly drop last frame's row
          # assignment first so the spec is what resolves.
          label.clear_layout_height
          if field = children[i + 1]?
            field.clear_layout_height
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
            place_child label, 0, y, lc, rh
            place_child field, lw + hs, y, fc, rh
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
            place_child label, 0, y, lc, rh
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
        # Re-wrap the label's content at its current effective width before
        # measuring: `_clines` is a render-time cache and may still hold lines
        # wrapped at last frame's assigned column (or older content). The old
        # spec-restoring bookkeeping caused this re-wrap as a side effect of
        # its `width=` restore (Resize -> reprocess); the layout channel asks
        # for it explicitly. Cache-keyed, so a stable label costs one key
        # check.
        el.process_content
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
    end
  end
end
