module Crysterm
  # Per-widget `#css_attributes` overrides: each stateful widget surfaces its
  # intrinsic state as HTML attributes in the CSS document so it can be targeted
  # by attribute selectors (e.g. `.w-checkbox[checked]`, `.w-button[checkable]`).
  #
  # Names are kept CSS/HTML-conventional (`checked`, `indeterminate`, ...). A
  # `nil` value emits a bare boolean attribute, present only while the state
  # holds — so `[checked]` matches exactly the checked widgets.
  #
  # Note: *disabled* is a `WidgetState`, not an attribute, so it is targeted with
  # the `:disabled` state pseudo-class rather than `[disabled]`.

  class Widget
    class Button
      def css_attributes : Hash(String, String?)
        attrs = {} of String => String?
        attrs["checkable"] = nil if checkable?
        attrs["checked"] = nil if checked?
        attrs
      end
    end

    class CheckBox
      # `RadioButton` (a `CheckBox` subclass) inherits this.
      def css_attributes : Hash(String, String?)
        attrs = {} of String => String?
        attrs["checked"] = nil if checked?
        attrs["indeterminate"] = nil if partial? # Qt's PartiallyChecked / CSS :indeterminate
        attrs
      end
    end
  end
end
