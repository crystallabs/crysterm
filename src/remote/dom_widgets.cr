module Crysterm
  # Per-widget layout-DOM overrides.
  #
  # Opt-in is automatic by namespace — every `Crysterm::Widget::*` is
  # serializable/loadable, with options derived from initializer arguments. A
  # widget appears here only when it needs to hand-write
  # `#dom_attributes`/`#dom_apply` for state the automatic scan can't express,
  # which also opts it out of that scan.
  class Widget
    class List
      # Rows are loadable state but don't fit the generic scan (no scalar
      # `items=`): serialized as a newline-joined `items` attribute, restored
      # via `#add_item`.
      def dom_attributes : Hash(String, String?)
        attrs = super
        attrs["items"] = item_texts.join('\n') unless item_texts.empty?
        attrs
      end

      def dom_apply(key : String, value : String?) : Bool
        case key
        when "items"
          # Replace, don't append: `setAttribute` has replace semantics, and at
          # load time the list is empty so clearing first is a no-op. Without the
          # clear, a repeated `setAttribute("items", …)` would grow the list on
          # every call.
          clear
          # An empty value skips the append: `"".split('\n') == [""]`, so
          # `setAttribute("items", "")` — the natural way a client clears the
          # rows — would otherwise add one empty item.
          value.try { |v| v.split('\n').each { |item| add_item item } unless v.empty? }
        else return super
        end
        true
      end
    end
  end
end
