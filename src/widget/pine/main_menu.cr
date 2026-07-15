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

      # <!-- widget-examples:capture v1 -->
      # ![MainMenu screenshot](../../../tests/widget/pine/main_menu/main_menu.5s.apng)
      # <!-- /widget-examples:capture -->
      class MainMenu < SelectableList(MenuOption)
        # Nested-name alias for the record type.
        alias Option = ::Crysterm::Widget::Pine::MenuOption

        def initialize(
          options : Array(Option) = [] of Option,
          *,
          # Blank rows between options (Pine spaces its menu out). The gaps are
          # not items: they can't be selected or clicked.
          spacing : Int32 = 1,
          **list,
        )
          # Must be assigned before `super` so the first layout uses it.
          @item_spacing = spacing
          super options, **list
        end

        record_accessors options, option, Option

        # Returns the option key for the currently-selected row, if any.
        def selected_key : String?
          selected_record.try &.key
        end

        # Formats one option into a fixed-column row. The indent is small because
        # Alpine centers the menu as a block.
        def format_row(item : Option, index : Int32) : String
          "    #{item.key.ljust(2)}    #{item.title.ljust(16)} -  #{item.description}"
        end
      end
    end
  end
end
