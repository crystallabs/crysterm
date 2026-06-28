module Crysterm
  class Widget
    # Box element
    #
    # <!-- widget-examples:capture v1 -->
    # ![Box screenshot](../../examples/widget/box/box-capture5s.apng)
    # <!-- /widget-examples:capture -->
    class Box < Widget
      # XXX Why this must be here, even though it's set in src/widget_size.cr?
      # Check e.g. tests/blessed-test/widget-shadow.cr with and without this option here.
      @resizable = false

      # `Box` is the first subclass of `Widget`, and the `Mixin::Css`-installed
      # `macro inherited` that generates each widget's `#css_type_classes` does not
      # fire for it (it fires for every *other* widget — `Input`, `Button`, …).
      # Without this, `Box` falls back to the base `["Widget"]`, so its CSS document
      # node carries no `Box` class and `Box { … }` / `Box#id` selectors silently
      # never match a plain `Box`. Define the chain explicitly (same shape the macro
      # emits) so type selectors work for `Box` like every other widget.
      CSS_TYPE_CLASSES = ["Box", "Widget"]

      def css_type_classes : Array(String)
        CSS_TYPE_CLASSES
      end

      # Same reason as `CSS_TYPE_CLASSES` above: the `inherited` macro that emits
      # each class's `#css_tag` doesn't fire for `Box`, so define it explicitly
      # (matching the macro's `w-` + lowercased-leaf form) — otherwise a plain
      # `Box` would serialize as `<w-widget>`.
      CSS_TAG = "w-box"

      def css_tag : String
        CSS_TAG
      end

      # Stamps `text` into the screen row at `y`, one glyph per cell starting at
      # column `x` and stopping before reaching `xl`, then marks the row dirty.
      # With a non-nil `attr` each touched cell's attribute is set as well;
      # otherwise only the glyph is written and the existing attribute is kept.
      # A shared primitive for the single-row text overlays drawn by
      # `Slider`/`Dial`/`ProgressBar`/`StatusBar` (each previously inlined this
      # same `screen.lines[y]?` + per-char write + `line.dirty` loop).
      protected def draw_text_run(y : Int32, x : Int32, text : String, xl : Int32, attr : Int64? = nil) : Nil
        screen.lines[y]?.try do |line|
          text.each_char_with_index do |ch, i|
            cx = x + i
            break if cx >= xl
            line[cx]?.try do |cell|
              cell.char = ch
              cell.attr = attr unless attr.nil?
            end
          end
          line.dirty = true
        end
      end
    end
  end
end
