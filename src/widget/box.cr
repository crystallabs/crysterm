module Crysterm
  class Widget
    # Box element
    #
    # <!-- widget-examples:capture v1 -->
    # ![Box screenshot](../../tests/widget/box/box.5s.apng)
    # <!-- /widget-examples:capture -->
    class Box < Widget
      # XXX Why must this be here, even though it's set in src/widget_size.cr?
      # See tests/blessed-test/widget-shadow.cr with and without this option.
      @resizable = false

      # `Box` is the first subclass of `Widget`, so the `Mixin::Css`-installed
      # `macro inherited` that generates `#css_type_classes` doesn't fire for it
      # (unlike every other widget). Without this, `Box` falls back to
      # `["Widget"]` and `Box { … }` / `Box#id` selectors never match. Defined
      # explicitly here in the same shape the macro emits.
      CSS_TYPE_CLASSES = ["Box", "Widget"]

      def css_type_classes : Array(String)
        CSS_TYPE_CLASSES
      end

      # Same reason as `CSS_TYPE_CLASSES`: the `inherited` macro that emits
      # `#css_tag` doesn't fire for `Box`, so define it explicitly (matching the
      # macro's `w-` + lowercased-leaf form) — otherwise it'd serialize as `<w-widget>`.
      CSS_TAG = "w-box"

      def css_tag : String
        CSS_TAG
      end

      # Stamps `text` into the window row at `y`, one glyph per cell starting at
      # column `x` and stopping before `xl`, then marks the row dirty. With a
      # non-nil `attr` each touched cell's attribute is set too; otherwise only
      # the glyph is written. Shared primitive for the single-row text overlays
      # drawn by `Slider`/`Dial`/`ProgressBar`/`StatusBar`.
      protected def draw_text_run(y : Int32, x : Int32, text : String, xl : Int32, attr : Int64? = nil) : Nil
        window.lines[y]?.try do |line|
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

      # Defines a `<name>=` setter for a boolean flag surfaced as a CSS attribute
      # selector (e.g. `Button[flat]`, `GroupBox[flat]`). On an actual change it
      # stores the value, re-cascades (`invalidate_css`) so `[<name>]` starts/stops
      # matching, and repaints. The flag itself is still declared with its own
      # `getter?`/default in each widget.
      private macro css_toggle_setter(name)
        def {{name.id}}=(value : Bool) : Bool
          return value if value == @{{name.id}}
          @{{name.id}} = value
          invalidate_css
          request_render
          value
        end
      end
    end
  end
end
