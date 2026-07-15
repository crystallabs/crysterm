module Crysterm
  # Per-widget layout-DOM overrides.
  #
  # Opt-in is automatic by namespace — every `Crysterm::Widget::*` is
  # serializable/loadable (see `dom_loader.cr` / `dom_autoserialize.cr`), with
  # options derived from initializer arguments. A widget appears here only when
  # it needs to hand-write `#dom_attributes`/`#dom_apply` for state the
  # automatic scan can't express, which also opts it out of that scan.
  class Widget
    class List
      # Rows are loadable state but don't fit the generic scan (no scalar
      # `items=`): serialized as a newline-joined `items` attribute, restored
      # via `#add_item`.
      def dom_attributes : Hash(String, String?)
        attrs = super
        attrs["items"] = ritems.join('\n') unless ritems.empty?
        attrs
      end

      def dom_apply(key : String, value : String?) : Bool
        case key
        when "items"
          # Replace, don't append: the bridge's `setAttribute` documents replace
          # semantics (`dom_http.cr`), and at load time the list is empty so
          # clearing first is a no-op. Without the clear, a repeated
          # `setAttribute("items", …)` (or a re-applied attribute) would grow the
          # list on every call — the same accumulation bug the `class` handler
          # avoids.
          clear
          # Skip the append for an empty value: `"".split('\n') == [""]`, so an
          # empty string (the natural way a bridge client clears the rows via
          # `setAttribute("items", "")`) would otherwise add one empty item
          # instead of leaving the list cleared.
          value.try { |v| v.split('\n').each { |item| add_item item } unless v.empty? }
        else return super
        end
        true
      end
    end
  end
end
