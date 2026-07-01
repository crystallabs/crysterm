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
      # via `#append_item`.
      def dom_attributes : Hash(String, String?)
        attrs = super
        attrs["items"] = ritems.join('\n') unless ritems.empty?
        attrs
      end

      def dom_apply(key : String, value : String?) : Bool
        case key
        when "items" then value.try &.split('\n').each { |item| append_item item }
        else              return super
        end
        true
      end
    end
  end
end
