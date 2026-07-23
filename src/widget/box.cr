module Crysterm
  class Widget
    # Box element
    #
    # <!-- widget-examples:capture v1 -->
    # ![Box screenshot](../../tests/widget/box/box.5s.apng)
    # <!-- /widget-examples:capture -->
    class Box < Widget
      # XXX Redundant with `Widget`'s own default, yet shadows misrender without it.
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

      # Stamps `text` into the window row at `y`, one glyph per cell starting at
      # column `x` and stopping before `xl`, then marks the row dirty. With a
      # non-nil `attr` each touched cell's attribute is set too; otherwise only
      # the glyph is written.
      protected def draw_text_run(y : Int32, x : Int32, text : String, xl : Int32, attr : Int64? = nil) : Nil
        # Negative indices would wrap (`Indexable#[]?` accepts them), stamping text
        # onto the far end of other rows for a widget partly off the top/left edge.
        return if y < 0
        window.lines[y]?.try do |line|
          text.each_char_with_index do |ch, i|
            cx = x + i
            break if cx >= xl
            next if cx < 0
            line[cx]?.try do |cell|
              cell.char = ch
              cell.attr = attr unless attr.nil?
            end
          end
          line.dirty = true
        end
      end

      # Centers `text` horizontally within `[xi, xl)` on row `y`, then stamps it
      # via `#draw_text_run` (clamping to `xl` and carrying `attr` the same way).
      protected def draw_centered_text(y : Int32, xi : Int32, xl : Int32, text : String, attr : Int64? = nil) : Nil
        cx = xi + Math.max(0, (xl - xi - text.size) // 2)
        draw_text_run y, cx, text, xl, attr
      end
    end
  end
end
