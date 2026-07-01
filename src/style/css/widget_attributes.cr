module Crysterm
  # Per-widget `#css_attributes` overrides: each stateful widget surfaces its
  # intrinsic state as HTML attributes in the CSS document so it can be targeted
  # by attribute selectors (e.g. `.w-checkbox[checked]`, `.w-button[checkable]`).
  #
  # Names are kept CSS/HTML-conventional (`checked`, `indeterminate`, ...). A
  # `nil` value emits a bare boolean attribute, present only while the state
  # holds.
  #
  # *disabled* is a `WidgetState`, not an attribute, so it's targeted with the
  # `:disabled` state pseudo-class rather than `[disabled]`.

  class Widget
    class Button
      def css_attributes : Hash(String, String?)
        # Plain push-button has none of these — reuse the shared empty.
        return EMPTY_CSS_ATTRIBUTES unless checkable? || flat? || default?
        attrs = {} of String => String?
        attrs["checkable"] = nil if checkable?
        if checkable?
          # Both checked and its complement surfaced: Qt's `:unchecked`/`:off`
          # become `[unchecked]` since `:not()` doesn't compile in our selector
          # engine.
          attrs[checked? ? "checked" : "unchecked"] = nil
        end
        # Qt's `:flat`/`:default` (see `CSS::Qss`); the theme's `Button[flat]`
        # strips the border.
        attrs["flat"] = nil if flat?
        attrs["default"] = nil if default?
        attrs
      end
    end

    class GroupBox
      # Qt's `:flat` → `[flat]`: a flat group box drops its frame
      # (`GroupBox[flat]` in the theme). `super.dup` before mutating, since the
      # base may hand back a shared empty hash.
      def css_attributes : Hash(String, String?)
        return super unless flat?
        attrs = super.dup
        attrs["flat"] = nil
        attrs
      end
    end

    # Widgets with an orientation surface it as a boolean attribute, so Qt's
    # `:horizontal`/`:vertical` (→ `[horizontal]`/`[vertical]`, see `CSS::Qss`)
    # can target them.
    {% for w in %w[ScrollBar Slider ProgressBar Splitter] %}
      class {{w.id}}
        def css_attributes : Hash(String, String?)
          attrs = super.dup # never mutate super's (possibly shared) result
          attrs[orientation.horizontal? ? "horizontal" : "vertical"] = nil
          attrs
        end
      end
    {% end %}

    class ComboBox
      # Qt's `:editable` → `[editable]` (see `CSS::Qss`).
      def css_attributes : Hash(String, String?)
        return super unless editable?
        attrs = super.dup
        attrs["editable"] = nil
        attrs
      end
    end

    class CheckBox
      # `RadioButton` (a `CheckBox` subclass) inherits this.
      def css_attributes : Hash(String, String?)
        attrs = {} of String => String?
        if partial?
          attrs["indeterminate"] = nil # Qt's PartiallyChecked / CSS :indeterminate
        else
          # Complementary `[checked]`/`[unchecked]` (Qt `:checked`/`:unchecked`,
          # `:on`/`:off`); `:not([checked])` can't be used.
          attrs[checked? ? "checked" : "unchecked"] = nil
        end
        attrs
      end
    end
  end
end
