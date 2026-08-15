module Crysterm
  class Widget
    # Box element
    #
    # <!-- widget-examples:capture v1 -->
    # ![Box screenshot](../../tests/widget/box/box.5s.apng)
    # <!-- /widget-examples:capture -->
    class Box < Widget
      # Required despite reading identically to `Widget`'s own `false` default —
      # `#shrink_to_fit?` is `false` here with or without this line, yet removing
      # it misrenders the box (verified: the golden changes, while the value does
      # not). A Crystal ivar-initialization quirk for `Box`, the first `Widget`
      # subclass — the same class of first-subclass issue that forces the explicit
      # `CSS_TYPE_CLASSES` / `CSS_TAG` below. Leave it in.
      @shrink_to_fit = false

      # `Box` is the first subclass of `Widget`, so the `Mixin::Css`-installed
      # `macro inherited` that generates `#css_type_classes` doesn't fire for it.
      # Without this, `Box` falls back to `["Widget"]` and `Box { … }` / `Box#id`
      # selectors never match. Defined explicitly in the shape the macro emits.
      CSS_TYPE_CLASSES = ["Box", "Widget"]

      def css_type_classes : Array(String)
        CSS_TYPE_CLASSES
      end

      # Same reason as `CSS_TYPE_CLASSES`: the `inherited` macro that emits
      # `#css_tag` doesn't fire for `Box`, so define it explicitly in the macro's
      # `w-` + lowercased-leaf form — otherwise it'd serialize as `<w-widget>`.
      CSS_TAG = "w-box"

      def css_tag : String
        CSS_TAG
      end

      # Low-level text stamp under `#draw_text_run` and the graph overlay's
      # `put_text`: writes `text` one glyph per cell into the window row at
      # `y`, starting at column `x` and clipped to the half-open column range
      # `[lo, hi)`, then marks exactly the stamped span dirty. With a non-nil
      # `attr` each touched cell's attribute is set too; otherwise only the
      # glyph is written.
      protected def stamp_text_run(y : Int32, x : Int32, text : String, lo : Int32, hi : Int32, attr : Int64? = nil) : Nil
        # Negative indices would wrap (`Indexable#[]?` accepts them), stamping
        # text onto the far end of other rows for a widget partly off the
        # top/left edge — guard the row, and clamp the clip floor so a negative
        # `lo` still rejects off-left columns.
        return if y < 0
        lo = 0 if lo < 0
        window.cell_rows[y]?.try do |line|
          text.each_char_with_index do |ch, i|
            cx = x + i
            break if cx >= hi
            next if cx < lo
            line[cx]?.try do |cell|
              cell.char = ch
              cell.attr = attr unless attr.nil?
            end
          end
          line.mark_dirty_range Math.max(x, lo), Math.min(x + text.size - 1, hi - 1)
        end
      end

      # Low-level single-cell stamp under `#put_cell` and the graph overlay's
      # `put_cell`: writes one glyph + packed attr at `(x, y)`, clipped to the
      # half-open column range `[lo, hi)`, and marks that column dirty.
      # Negative coordinates are dropped (`Indexable#[]?` would wrap them onto
      # the far end of other rows/columns).
      protected def stamp_cell(x : Int32, y : Int32, ch : Char, attr : Int64, lo : Int32, hi : Int32) : Nil
        return if y < 0
        lo = 0 if lo < 0
        return if x < lo || x >= hi
        window.cell_rows[y]?.try do |line|
          line[x]?.try do |cell|
            cell.char = ch
            cell.attr = attr
            line.mark_dirty x
          end
        end
      end

      # Stamps `text` into the window row at `y`, one glyph per cell starting at
      # column `x` and stopping before `xl`. With a non-nil `attr` each touched
      # cell's attribute is set too; otherwise only the glyph is written.
      protected def draw_text_run(y : Int32, x : Int32, text : String, xl : Int32, attr : Int64? = nil) : Nil
        stamp_text_run y, x, text, 0, xl, attr
      end

      # Centers `text` horizontally within `[xi, xl)` on row `y`, then stamps it
      # via `#draw_text_run` (clamping to `xl` and carrying `attr` the same way).
      protected def draw_centered_text(y : Int32, xi : Int32, xl : Int32, text : String, attr : Int64? = nil) : Nil
        cx = xi + Math.max(0, (xl - xi - text.size) // 2)
        draw_text_run y, cx, text, xl, attr
      end

      # Writes one glyph + packed attr directly into the window buffer at
      # `(x, y)` — the single-cell sibling of `#draw_text_run`. When *clip* is
      # given, any cell outside that rendered clip rectangle (a partially
      # offscreen or ancestor-clipped widget) is dropped.
      protected def put_cell(x : Int32, y : Int32, ch : Char, attr : Int64, clip : RenderedGeometry? = nil) : Nil
        return if clip && !clip.contains?(x, y)
        stamp_cell x, y, ch, attr, 0, Int32::MAX
      end
    end
  end
end
