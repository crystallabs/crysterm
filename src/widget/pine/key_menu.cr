module Crysterm
  class Widget
    module Pine
      # The two-row command-key menu shown at the bottom of every Pine/Alpine
      # screen.
      #
      # Each entry is a `key` (the keyboard character the user presses) plus a
      # short `label` describing what it does. Entries are laid out in a grid of
      # `columns` columns and (by default) two rows, filling column-by-column
      # exactly like Pine: the first entry goes top-left, the second directly
      # below it, the third to the top of the next column, and so on.
      #
      # The widget is purely presentational — it draws the hints. Wire the actual
      # keys up with a `Screen`/`Widget` `Event::KeyPress` handler (the `key`
      # values here are meant to mirror those bindings). Each entry may carry an
      # optional `callback`, which `#trigger` can invoke if you want the menu to
      # double as a dispatch table.
      #
      # ```
      # menu = Widget::Pine::KeyMenu.new parent: screen, bottom: 0, entries: [
      #   Widget::Pine::KeyMenu::Entry.new("?", "Help"),
      #   Widget::Pine::KeyMenu::Entry.new("O", "OTHER CMDS"),
      #   Widget::Pine::KeyMenu::Entry.new("C", "Compose"),
      # ]
      # ```
      class KeyMenu < Widget::Box
        # A single command hint in the menu.
        class Entry
          # The keyboard key that triggers the command (shown highlighted).
          property key : String

          # Human-readable description of the command.
          property label : String

          # Optional action invoked by `KeyMenu#trigger`.
          property callback : Proc(Nil)?

          def initialize(@key, @label, @callback = nil)
          end
        end

        # The entries currently shown.
        getter entries : Array(Entry)

        # Number of columns to arrange entries into.
        property columns : Int32

        # Number of rows (Pine uses 2).
        property rows : Int32

        # Style used to highlight the key character.
        property key_style : Style

        # Generated child boxes, one per visible entry (parallel to `#entries`).
        getter cells = [] of Widget::Box

        def initialize(
          entries : Array(Entry) = [] of Entry,
          *,
          @columns = 6,
          @rows = 2,
          @key_style = Style.new(inverse: true),
          height h = nil, width w = "100%",
          **layout,
        )
          @entries = entries
          super **layout, width: w, height: (h || rows)
          build
        end

        # Replaces all entries and rebuilds the display. Use this when switching
        # between Pine screens, each of which has its own command set.
        def set_entries(entries : Array(Entry))
          @entries = entries
          build
        end

        # Invokes the callback of the entry whose `key` matches *key* (if any),
        # returning `true` when something was triggered. Lets the menu act as a
        # dispatch table for the bottom-bar keys.
        def trigger(key : String) : Bool
          @entries.each do |e|
            if e.key == key
              e.callback.try &.call
              return true
            end
          end
          false
        end

        # (Re)creates the child boxes for the current entries.
        private def build
          @cells.each &.remove_from_parent
          @cells.clear

          col_pct = 100 // @columns

          @entries.each_with_index do |entry, i|
            col = i // @rows
            row = i % @rows
            next if col >= @columns

            left = col == 0 ? 0 : "#{col * col_pct}%"
            width = "#{col_pct}%"

            box = Widget::Box.new(
              screen: screen,
              parse_tags: true,
              top: row,
              left: left,
              width: width,
              height: 1,
              content: format_entry(entry),
            )

            @cells << box
            append box
          end
        end

        # Builds the tagged content for a single entry: a highlighted key
        # followed by its label, e.g. `{inverse} ? {/inverse} Help`.
        private def format_entry(entry : Entry) : String
          tags = key_tags
          "#{tags[:open]} #{entry.key} #{tags[:close]} #{entry.label}"
        end

        # Translates `key_style` into open/close tags used around the key.
        private def key_tags
          if @key_style.inverse?
            {open: "{inverse}", close: "{/inverse}"}
          elsif (fg = @key_style.fg) && fg >= 0
            hex = "#%06x" % (fg & 0xffffff)
            {open: "{#{hex}-fg}", close: "{/#{hex}-fg}"}
          else
            {open: "{bold}", close: "{/bold}"}
          end
        end
      end
    end
  end
end
