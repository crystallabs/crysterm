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
    end
  end
end
