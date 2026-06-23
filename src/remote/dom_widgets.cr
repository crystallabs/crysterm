module Crysterm
  # Per-widget layout-DOM overrides.
  #
  # Opt-in is now automatic by namespace — every `Crysterm::Widget::*` is
  # serializable and loadable (see `dom_loader.cr` / `dom_autoserialize.cr`), and
  # each widget's options are derived from its initializer arguments. So a widget
  # appears here only when it needs to hand-write `#dom_attributes`/`#dom_apply`
  # for state the automatic scan can't express — which also opts it out of the
  # scan.
  class Widget
    class List
      # The list's rows are part of its loadable state, but they don't fit the
      # generic scan (no scalar `items=`): they are serialized as a single
      # newline-joined `items` attribute and restored via `#append_item`.
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
