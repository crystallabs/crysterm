require "../../widget_pine_selectable_list"

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
      # The currently-selected row is drawn reverse. Navigate with the arrow keys
      # and activate with Enter; activation runs the option's `callback` (and also
      # emits `Event::ActionItem`, so callers can hook in instead).
      #
      # <!-- widget-examples:capture v1 -->
      # ![MainMenu screenshot](../../../examples/widget/pine/main_menu/main_menu-capture5s.apng)
      # <!-- /widget-examples:capture -->
      # A single selectable menu command.
      class MenuOption
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

      class MainMenu < SelectableList(MenuOption)
        # Historical nested name for the record type (see `SelectableList`).
        alias Option = ::Crysterm::Widget::Pine::MenuOption

        # Whether to insert a blank spacer line between options (as Pine does).
        property? spaced : Bool

        def initialize(
          options : Array(Option) = [] of Option,
          *,
          @spaced = true,
          **list,
        )
          super options, **list
        end

        # The options currently displayed, parallel to the list items.
        def options : Array(Option)
          records
        end

        # Replaces the menu's options and rebuilds the visible rows.
        def set_options(options : Array(Option))
          set_records options
        end

        # Activates the currently-selected option, invoking its callback.
        def run_selected
          activate
        end

        # Returns the option key for the currently-selected row, if any.
        def selected_key : String?
          selected_record.try &.key
        end

        # With spacer lines present, every other list item is a blank separator;
        # map the list index back to the option index.
        protected def selected_index : Int32
          @spaced ? selected // 2 : selected
        end

        # Builds the list-item strings (with blank spacers when `spaced?`).
        protected def rows(data : Array(Option)) : Array(String)
          return super unless @spaced
          lines = [] of String
          data.each_with_index do |o, i|
            lines << format_row(o, i)
            lines << "" if i < data.size - 1
          end
          lines
        end

        # Formats one option into a fixed-column row. The row is kept compact
        # (small left indent) because the menu is normally centered as a block,
        # the way Alpine presents it.
        def format_row(item : Option, index : Int32) : String
          "    #{item.key.ljust(2)}    #{item.title.ljust(16)} -  #{item.description}"
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
