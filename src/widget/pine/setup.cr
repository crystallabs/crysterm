module Crysterm
  class Widget
    module Pine
      # The Pine/Alpine SETUP / CONFIGURATION screen: a scrollable list of
      # on/off configuration features, each drawn with a checkbox-style prefix:
      #
      # ```
      # [ ]  enable-incoming-folders     Show the incoming-folders collection
      # [X]  enable-aggregate-commands   Allow operating on several messages
      # ```
      #
      # Navigate with the arrow keys; toggle the selected feature with Enter or
      # the space bar. The selected row is drawn reverse.
      #
      # <!-- widget-examples:capture v1 -->
      # ![Setup screenshot](../../../examples/widget/pine/setup/setup-capture.png)
      # <!-- /widget-examples:capture -->
      class Setup < Widget::List
        # A single configurable feature.
        class Option
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

        # The configurable options, parallel to the list rows.
        getter options = [] of Option

        def initialize(
          options : Array(Option) = [] of Option,
          **list,
        )
          super **list

          styles.selected = Style.new reverse: true

          set_options options

          on ::Crysterm::Event::ActionItem do |e|
            toggle_selected
          end
        end

        # Replaces the displayed options.
        def set_options(options : Array(Option))
          @options = options
          set_items options.map { |o| format_option o }
        end

        # The currently-selected option, if any.
        def selected_option : Option?
          @options[selected]?
        end

        # Toggles the currently-selected option and refreshes its row.
        def toggle_selected
          o = @options[selected]?
          return unless o
          o.enabled = !o.enabled?
          set_item selected, format_option(o)
          o.callback.try &.call(o.enabled?)
          request_render
        end

        # Formats one option into a `[X]`/`[ ]`-prefixed row.
        private def format_option(o : Option) : String
          mark = o.enabled? ? "X" : " "
          "  [#{mark}]  #{o.name.ljust(32)}#{o.description}"
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
