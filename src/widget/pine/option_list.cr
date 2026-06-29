require "../../widget_pine_selectable_list"

module Crysterm
  class Widget
    module Pine
      # The kind of value an `OptionListOption` holds, and therefore how the row
      # is rendered and what activating it (Enter) does.
      enum OptionKind
        # An on/off boolean, drawn `[X]`/`[ ]`; Enter or Space flips it.
        Toggle
        # A free-form string, edited inline; Enter starts/commits editing.
        Text
        # An integer string, edited inline like `Text` but only digits (and a
        # leading `-`) are accepted; Enter starts/commits editing.
        Number
        # One of a fixed list of `allowed` values; Enter advances to the next
        # (wrapping back to the first after the last).
        Choice
      end

      # A single configurable option in an `OptionList`.
      #
      # The value is stored canonically as a `String` regardless of `kind`; the
      # typed accessors (`#on?`, `#to_i`) interpret it. This keeps the record
      # trivially copyable/serializable and lets one list mix every `OptionKind`.
      class OptionListOption
        # Internal option name / label (e.g. `"line-wrap"`).
        property name : String

        # What sort of value this option holds (see `OptionKind`).
        property kind : OptionKind

        # Short explanation shown to the right.
        property description : String

        # The current value, stored as a `String` for every `kind`:
        # `"true"`/`"false"` for `Toggle`, the digits for `Number`, the raw
        # string for `Text`, and one of `allowed` for `Choice`.
        property value : String

        # The permitted values, used only by `OptionKind::Choice`.
        property allowed : Array(String)

        # Optional callback invoked with the new (committed) value whenever it
        # changes.
        property callback : Proc(String, Nil)?

        def initialize(
          @name,
          @kind : OptionKind = OptionKind::Text,
          @description = "",
          *,
          @value = "",
          @allowed = [] of String,
          @callback = nil,
        )
        end

        # `true` when a `Toggle` option is on (its `value` is `"true"`).
        def on? : Bool
          @value == "true"
        end

        # The value parsed as an integer (for `Number`), or `nil` if unparsable.
        def to_i : Int32?
          @value.to_i?
        end
      end

      # The Pine/Alpine SETUP/CONFIGURATION editor generalized: a scrollable list
      # of named options, each of a `OptionKind` (toggle / text / number /
      # choice), edited in place. It is the richer sibling of the toggle-only
      # `Setup` widget.
      #
      # Each row shows the option name, a type-appropriate value display, and the
      # description:
      #
      # ```
      # [X]  line-wrap                       Wrap long lines
      #      username    crysterm            Name shown to others
      #      tab-width   4                    Spaces per tab
      #      theme       dark                 Color theme
      # ```
      #
      # Navigate with the arrow keys. Enter activates the selected option:
      #
      # * **Toggle** — flips it (Space also toggles).
      # * **Choice** — advances to the next `allowed` value, wrapping.
      # * **Text** / **Number** — begins inline editing; type to edit, Backspace
      #   deletes, Enter commits, Esc cancels. `Number` accepts only digits and a
      #   leading `-`.
      #
      # On every committed change the row is refreshed and the option's
      # `callback` is invoked with the new value. The selected row is drawn
      # reverse.
      #
      # ```
      # ol = Crysterm::Widget::Pine::OptionList.new parent: screen
      # ol.set_options [
      #   Crysterm::Widget::Pine::OptionList::Option.new("line-wrap",
      #     Crysterm::Widget::Pine::OptionKind::Toggle,
      #     "Wrap long lines", value: "true"),
      #   Crysterm::Widget::Pine::OptionList::Option.new("theme",
      #     Crysterm::Widget::Pine::OptionKind::Choice,
      #     "Color theme", value: "dark", allowed: %w[dark light solarized]),
      # ]
      # ol.focus
      # ol.value("theme") # => "dark"
      # ```
      #
      # <!-- widget-examples:capture v1 -->
      # ![OptionList screenshot](../../../examples/widget/pine/option_list/option_list-capture5s.apng)
      # <!-- /widget-examples:capture -->
      class OptionList < SelectableList(OptionListOption)
        # Historical nested name for the record type (see `SelectableList`).
        alias Option = ::Crysterm::Widget::Pine::OptionListOption

        # Width of the option-name column, in characters.
        VALUE_COLUMN = 24

        # Width of the value column, in characters.
        DESC_COLUMN = 20

        # Whether a `Text`/`Number` option is currently being edited inline.
        getter? editing : Bool = false

        # The in-progress edit text while `editing?`; `nil` otherwise.
        @edit_buffer : String? = nil

        # The record index currently being edited, captured when editing begins.
        # Editing is anchored to THIS row — not the live `selected` — because a
        # mouse click moves the selection *before* it emits the activating
        # `ActionItem`, so committing against `selected` would write the edit into
        # whatever row was just clicked rather than the one being edited.
        @edit_index : Int32? = nil

        def initialize(
          options : Array(Option) = [] of Option,
          **list,
        )
          super options, **list

          # A click on another row moves the selection (emitting `SelectItem`)
          # before it activates the row. If an inline edit is in progress on a
          # different row, finish it now so the edit never lingers on the old row
          # until a second click.
          on ::Crysterm::Event::SelectItem do
            commit_edit if @editing && @edit_index != selected
          end
        end

        record_accessors options, option, Option

        # The current value of the option named *name*, or `nil` if no such
        # option exists.
        def value(name : String) : String?
          records.find { |o| o.name == name }.try &.value
        end

        # Enter (via `Event::ActionItem`) edits the selected option according to
        # its `kind` rather than running a one-shot callback.
        def activate
          # While editing, ANY activation (Enter, or a click that just moved the
          # selection to another row) commits the in-progress edit to its own
          # row and stops — it must not act on the newly-selected row.
          if @editing
            commit_edit
            return
          end
          o = records[selected]?
          return unless o
          case o.kind
          in OptionKind::Toggle
            toggle_selected
          in OptionKind::Choice
            advance_choice o
          in OptionKind::Text, OptionKind::Number
            begin_edit
          end
        end

        # Toggles the currently-selected `Toggle` option and refreshes its row.
        def toggle_selected
          o = records[selected]?
          return unless o && o.kind.toggle?
          o.value = o.on? ? "false" : "true"
          commit_change o, selected
        end

        # Advances a `Choice` option to its next `allowed` value (wrapping).
        private def advance_choice(o : Option)
          return if o.allowed.empty?
          i = o.allowed.index(o.value) || -1
          o.value = o.allowed[(i + 1) % o.allowed.size]
          commit_change o, selected
        end

        # Refreshes option *o*'s row at *index*, fires its callback, re-renders.
        private def commit_change(o : Option, index : Int32)
          set_item index, format_row(o, index)
          o.callback.try &.call(o.value)
          request_render
        end

        # Begins inline editing of the selected `Text`/`Number` option.
        def begin_edit
          o = records[selected]?
          return unless o && (o.kind.text? || o.kind.number?)
          @editing = true
          @edit_index = selected
          @edit_buffer = o.value
          refresh_editing_row
        end

        # Commits the in-progress inline edit into the edited option's value.
        def commit_edit
          idx = @edit_index
          buf = @edit_buffer
          @editing = false
          @edit_buffer = nil
          @edit_index = nil
          return unless idx && buf
          o = records[idx]?
          return unless o
          o.value = buf
          commit_change o, idx
        end

        # Cancels the in-progress inline edit, discarding the typed text.
        def cancel_edit
          idx = @edit_index
          @editing = false
          @edit_buffer = nil
          @edit_index = nil
          o = records[idx]? if idx
          set_item idx, format_row(o, idx) if idx && o
          request_render
        end

        # Redraws the row currently being edited, showing the edit buffer.
        private def refresh_editing_row
          idx = @edit_index
          return unless idx
          o = records[idx]?
          set_item idx, format_row(o, idx) if o
          request_render
        end

        # Formats one option into a fixed-column row: an optional `[X]`/`[ ]`
        # mark, the name, the value display, and the description.
        def format_row(item : Option, index : Int32) : String
          mark = item.kind.toggle? ? (item.on? ? "[X]" : "[ ]") : "   "
          "  #{mark} #{item.name.ljust(VALUE_COLUMN)}#{value_display(item, index).ljust(DESC_COLUMN)}#{item.description}"
        end

        # The value shown in the value column for *item*. While editing the
        # selected row a trailing cursor is appended.
        private def value_display(item : Option, index : Int32) : String
          if @editing && index == @edit_index
            "#{@edit_buffer}_"
          else
            case item.kind
            in OptionKind::Toggle
              "" # the mark already conveys the value
            in OptionKind::Text, OptionKind::Number, OptionKind::Choice
              item.value
            end
          end
        end

        # Adds inline-editing keys and Space-toggling on top of the inherited
        # arrow/Enter handling.
        def on_keypress(e)
          if @editing
            handle_edit_key e
            return
          end

          if e.char == ' '
            o = records[selected]?
            if o && o.kind.toggle?
              toggle_selected
              return
            end
          end

          super
        end

        # Handles a keypress while inline editing a `Text`/`Number` option.
        private def handle_edit_key(e)
          case e.key
          when ::Tput::Key::Enter
            commit_edit
          when ::Tput::Key::Escape
            cancel_edit
          when ::Tput::Key::Backspace
            buf = @edit_buffer
            if buf && !buf.empty?
              @edit_buffer = buf[0...-1]
              refresh_editing_row
            end
          else
            insert_char e.char
          end
        end

        # Appends a printable character to the edit buffer, enforcing the
        # `Number` constraint (digits and a single leading `-`).
        private def insert_char(c : Char)
          return if c == '\0' || c.ord < 32
          idx = @edit_index
          return unless idx
          o = records[idx]?
          return unless o
          if o.kind.number?
            buf = @edit_buffer || ""
            return unless c.ascii_number? || (c == '-' && buf.empty?)
          end
          @edit_buffer = (@edit_buffer || "") + c
          refresh_editing_row
        end
      end
    end
  end
end
