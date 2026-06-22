module Crysterm
  class Widget
    module Pine
      # The Pine/Alpine MAIN MENU: a vertical list of commands, each shown as a
      # highlighted key letter, an upper-cased title, and a short description:
      #
      # ```
      #          ?     HELP               -  Get help using Alpine
      #
      #          C     COMPOSE MESSAGE    -  Compose and send a message
      #
      #          I     MESSAGE INDEX      -  View messages in current folder
      # ```
      #
      # The currently-selected row is drawn inverse. Navigate with the arrow keys
      # and activate with Enter; activation runs the option's `callback` (and also
      # emits `Event::ActionItem`, so callers can hook in instead).
      class MainMenu < Widget::List
        # A single selectable menu command.
        class Option
          # Keyboard letter for the command (e.g. `"C"`).
          property key : String

          # Upper-cased command title (e.g. `"COMPOSE MESSAGE"`).
          property title : String

          # One-line explanation shown to the right.
          property description : String

          # Action invoked when the option is activated.
          property callback : Proc(Nil)?

          def initialize(@key, @title, @description, @callback = nil)
          end
        end

        # The options currently displayed, parallel to the list items.
        getter options = [] of Option

        # Whether to insert a blank spacer line between options (as Pine does).
        property? spaced : Bool

        def initialize(
          options : Array(Option) = [] of Option,
          *,
          @spaced = true,
          **list,
        )
          super **list

          # Pine highlights the whole selected row in inverse video.
          styles.selected = Style.new inverse: true

          set_options options

          # Run the activated option's callback (Enter / click).
          on ::Crysterm::Event::ActionItem do |e|
            run_selected
          end
        end

        # Replaces the menu's options and rebuilds the visible rows.
        def set_options(options : Array(Option))
          @options = options
          set_items rows(options)
        end

        # Activates the currently-selected option, invoking its callback.
        def run_selected
          # With spacer lines present, every other list item is a blank
          # separator; map the list index back to the option index.
          idx = @spaced ? selected // 2 : selected
          @options[idx]?.try &.callback.try &.call
        end

        # Returns the option key for the currently-selected row, if any.
        def selected_key : String?
          idx = @spaced ? selected // 2 : selected
          @options[idx]?.try &.key
        end

        # Builds the list-item strings (with blank spacers when `spaced?`).
        private def rows(options : Array(Option)) : Array(String)
          lines = [] of String
          options.each_with_index do |o, i|
            lines << format_option(o)
            lines << "" if @spaced && i < options.size - 1
          end
          lines
        end

        # Formats one option into a fixed-column row. The row is kept compact
        # (small left indent) because the menu is normally centered as a block,
        # the way Alpine presents it.
        private def format_option(o : Option) : String
          "    #{o.key.ljust(2)}    #{o.title.ljust(16)} -  #{o.description}"
        end

        # Skip over blank spacer rows when navigating with the arrow keys so the
        # selection always lands on a real option.
        def on_keypress(e)
          return super unless @spaced

          case e.key
          when ::Tput::Key::Up
            move_to_option(-1)
            request_render
          when ::Tput::Key::Down
            move_to_option(1)
            request_render
          else
            super
          end
        end

        # Moves the selection by *direction* (±1) options, hopping over spacers.
        private def move_to_option(direction)
          target = selected + direction * 2
          return if target < 0 || target >= @items.size
          selekt target
        end
      end
    end
  end
end
