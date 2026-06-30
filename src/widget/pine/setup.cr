require "../../widget_pine_selectable_list"

module Crysterm
  class Widget
    module Pine
      # The Pine/Alpine SETUP / CONFIGURATION window: a scrollable list of
      # on/off configuration features, each drawn with a checkbox-style prefix:
      #
      # ```
      # [ ]  enable-incoming-folders     Show the incoming-folders collection
      # [X]  enable-aggregate-commands   Allow operating on several messages
      # ```
      #
      # Navigate with the arrow keys; toggle the selected feature with Enter or
      # the space bar. The selected row is drawn reverse.
      # A single configurable feature.
      class SetupOption
        # Internal feature name (Pine-style, e.g. `"enable-incoming-folders"`).
        property name : String

        # Short explanation shown to the right.
        property description : String

        # Whether the feature is currently on.
        property? enabled : Bool

        # Optional callback invoked whenever the value is toggled.
        property callback : Proc(Bool, Nil)?

        def initialize(@name, @description = "", *, @enabled = false, @callback = nil)
        end
      end

      # <!-- widget-examples:capture v1 -->
      # ![Setup screenshot](../../../tests/widget/pine/setup/setup.5s.apng)
      # <!-- /widget-examples:capture -->
      class Setup < SelectableList(SetupOption)
        # Historical nested name for the record type (see `SelectableList`).
        alias Option = ::Crysterm::Widget::Pine::SetupOption

        def initialize(
          options : Array(Option) = [] of Option,
          **list,
        )
          super options, **list
        end

        record_accessors options, option, Option

        # Enter (via `Event::ActionItem`) toggles the selected option rather than
        # running a one-shot callback.
        def activate
          toggle_selected
        end

        # Toggles the currently-selected option and refreshes its row.
        def toggle_selected
          o = records[selected]?
          return unless o
          o.enabled = !o.enabled?
          set_item selected, format_row(o, selected)
          o.callback.try &.call(o.enabled?)
          request_render
        end

        # Formats one option into a `[X]`/`[ ]`-prefixed row.
        def format_row(item : Option, index : Int32) : String
          mark = item.enabled? ? "X" : " "
          "  [#{mark}]  #{item.name.ljust(32)}#{item.description}"
        end

        # Add space-bar toggling on top of the inherited arrow/Enter handling.
        def on_keypress(e)
          if e.char == ' '
            toggle_selected
            return
          end
          super
        end
      end
    end
  end
end
