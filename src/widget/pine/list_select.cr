require "../../widget_pine_selectable_list"

module Crysterm
  class Widget
    module Pine
      # A generic "select from a list" picker — the reusable counterpart of the
      # Pine/Alpine `select_from_list` family. Shows a scrollable list of
      # arbitrary items and lets the user pick one (single-select) or check
      # several with `[X]` checkboxes (multi-select), confirming with Enter.
      # Think of it as a terminal `<select>` / `<select multiple>`.
      #
      # The widget is fully generic over the item type `T`: the caller supplies a
      # *label* proc describing how to render each item, so it carries no domain
      # semantics of its own.
      #
      # Single-select (Enter confirms the highlighted item):
      #
      # ```
      # Apricot
      # Banana
      # Cherry
      # ```
      #
      # Multi-select (space toggles, Enter confirms all checked items):
      #
      # ```
      #   [ ]  Apricot
      #   [X]  Banana
      #   [X]  Cherry
      # ```
      #
      # Navigate with the arrow keys; in multi mode press the space bar to toggle
      # the current row's checkbox. Press Enter to confirm: the `on_confirm`
      # callback (if any) runs with the chosen items, and `#selection` returns
      # them (the checked items in multi mode, or the single highlighted item in
      # single mode). The selected row is drawn reverse.
      #
      # ```
      # items = ["Apricot", "Banana", "Cherry"]
      # picker = Crysterm::Widget::Pine::ListSelect(String).new(
      #   items,
      #   label: ->(s : String) { s },
      #   multi: true,
      #   parent: screen,
      #   on_confirm: ->(chosen : Array(String)) {
      #     puts "picked: #{chosen.join(", ")}"
      #   })
      # picker.focus
      # ```
      #
      # <!-- widget-examples:capture v1 -->
      # ![ListSelect screenshot](../../../tests/widget/pine/list_select/list_select.5s.apng)
      # <!-- /widget-examples:capture -->
      class ListSelect(T) < SelectableList(T)
        # Whether the picker is in multi-select (checkbox) mode.
        getter? multi : Bool

        # The 0-based indices of the currently-checked items (multi mode only).
        getter checked_indices : Set(Int32)

        # Optional callback invoked on confirm (Enter) with the chosen items
        # (see `#selection`).
        property on_confirm : Proc(Array(T), Nil)?

        def initialize(
          items : Array(T) = [] of T,
          *,
          label : T -> String,
          multi : Bool = false,
          on_confirm : Proc(Array(T), Nil)? = nil,
          **list,
        )
          # Assigned before `super` because the base's `super` runs
          # `set_records`, which calls `#format_row` (which needs both).
          @label = label
          @multi = multi
          @checked_indices = Set(Int32).new
          @on_confirm = on_confirm

          super items, **list

          # In multi mode a click toggles the row's checkbox (like Space) rather
          # than confirming — see `#activate`.
          self.activate_on_click = true if @multi
        end

        # Exposes the displayed items under a domain-neutral name (alias of the
        # base `#records`).
        def options : Array(T)
          records
        end

        # Replaces the displayed items, clearing any checked state and rebuilding
        # the rows.
        def set_options(options : Array(T))
          @checked_indices.clear
          set_records options
        end

        # The items the user has checked, in list order (multi mode). In single
        # mode this is always empty — use `#selection` instead.
        def checked : Array(T)
          @checked_indices.to_a.sort!.compact_map { |i| records[i]? }
        end

        # The chosen items: the checked items in multi mode, or the single
        # highlighted item (wrapped in an array) in single mode. Empty if nothing
        # is selected.
        def selection : Array(T)
          if @multi
            checked
          elsif r = selected_record
            [r]
          else
            [] of T
          end
        end

        # Checks every item (multi mode only).
        def select_all
          return unless @multi
          records.each_index { |i| @checked_indices.add i }
          refresh_rows
        end

        # Unchecks every item.
        def clear_selection
          @checked_indices.clear
          refresh_rows
        end

        # Replaces the checked set with *items* (multi mode) — e.g. to preselect
        # the entries that are already active before showing the picker. Items not
        # present in the list are ignored.
        def set_checked(items : Enumerable(T))
          return unless @multi
          @checked_indices.clear
          items.each do |item|
            if i = records.index(item)
              @checked_indices.add i
            end
          end
          refresh_rows
        end

        # Toggles the checked state of the current row (multi mode only) and
        # refreshes it.
        def toggle_selected
          return unless @multi
          i = selected_index
          return unless records[i]?
          if @checked_indices.includes?(i)
            @checked_indices.delete i
          else
            @checked_indices.add i
          end
          set_item selected, format_row(records[i], i)
          request_render
        end

        # Invoked on `Event::ActionItem` (Enter / click). In multi mode toggles
        # the current row's checkbox without dismissing the list (read
        # `#checked`/`#selection` when the user leaves). In single mode confirms
        # the highlighted item via `on_confirm`.
        def activate
          if @multi
            toggle_selected
          else
            @on_confirm.try &.call(selection)
          end
        end

        # Confirms the current `#selection` via `on_confirm`, regardless of mode.
        # Hosts call this to apply a multi-select (e.g. when the user presses a
        # dedicated key or leaves the picker).
        def confirm
          @on_confirm.try &.call(selection)
        end

        # Renders one item into its row, prefixing a `[X]`/`[ ]` checkbox in
        # multi mode.
        def format_row(item : T, index : Int32) : String
          text = @label.call(item)
          if @multi
            mark = @checked_indices.includes?(index) ? "X" : " "
            "  [#{mark}]  #{text}"
          else
            "  #{text}"
          end
        end

        # Add space-bar toggling (multi mode) on top of the inherited arrow/Enter
        # handling.
        def on_keypress(e)
          if @multi && e.char == ' '
            toggle_selected
            e.accept
            return
          end
          super
        end

        # Rebuilds every visible row in place from the current records (e.g.
        # after a bulk checkbox change), preserving the cursor position.
        private def refresh_rows
          records.each_with_index do |item, i|
            set_item i, format_row(item, i)
          end
          request_render
        end
      end
    end
  end
end
