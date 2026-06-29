module Crysterm
  class Widget
    module Pine
      # The two-row command-key menu shown at the bottom of every Pine/Alpine
      # window.
      #
      # Each entry is a `key` (the keyboard character the user presses) plus a
      # short `label` describing what it does. Entries are laid out in a grid of
      # `columns` columns and (by default) two rows, filling column-by-column
      # exactly like Pine: the first entry goes top-left, the second directly
      # below it, the third to the top of the next column, and so on.
      #
      # The widget is purely presentational — it draws the hints. Wire the actual
      # keys up with a `Window`/`Widget` `Event::KeyPress` handler (the `key`
      # values here are meant to mirror those bindings). Each entry may carry an
      # optional `callback`, which `#trigger` can invoke if you want the menu to
      # double as a dispatch table.
      #
      # ```
      # menu = Widget::Pine::KeyMenu.new parent: window, bottom: 0, entries: [
      #   Widget::Pine::KeyMenu::Entry.new("?", "Help"),
      #   Widget::Pine::KeyMenu::Entry.new("O", "OTHER CMDS"),
      #   Widget::Pine::KeyMenu::Entry.new("C", "Compose"),
      # ]
      # ```
      #
      # <!-- widget-examples:capture v1 -->
      # ![KeyMenu screenshot](../../../examples/widget/pine/key_menu/key_menu-capture5s.apng)
      # <!-- /widget-examples:capture -->
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
          @key_style = Style.new(reverse: true),
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

        # Re-tile the cells across the full content width every paint, now that the
        # resolved width is known (like `ToolBox`/`Splitter`/`MainWindow`). The old
        # per-column `100 // columns` percentage rounded each column independently,
        # so the columns drifted apart (a stray cell of gap between them) and the
        # rightmost stopped short of the right edge whenever `columns` did not
        # divide 100 evenly — leaving the bottom command bar with ragged gaps. The
        # integer split below shares each boundary (`col * inner // n`), so columns
        # abut exactly and the last reaches the edge for any `columns`/width.
        def render(with_children = true)
          relayout
          super
        end

        # Positions every cell into its column using integer division on the
        # resolved content width, so the columns tile the full width with no gaps.
        private def relayout : Nil
          return if @cells.empty?
          inner = (awidth - iwidth) rescue return
          return if inner <= 0
          n = @columns
          @cells.each_with_index do |box, i|
            col = i // @rows
            l = col * inner // n
            r = (col + 1) * inner // n
            box.left = l
            box.width = r - l
          end
        end

        # (Re)creates the child boxes for the current entries. Each cell's column
        # position is assigned per frame by `#relayout`; here we only set the row
        # (within the `rows`-row grid) and its content.
        private def build
          @cells.each &.remove_from_parent
          @cells.clear

          @entries.each_with_index do |entry, i|
            col = i // @rows
            row = i % @rows
            next if col >= @columns

            box = Widget::Box.new(
              window: window,
              parse_tags: true,
              top: row,
              height: 1,
              content: format_entry(entry),
            )

            @cells << box
            append box
          end
        end

        # Builds the tagged content for a single entry: a highlighted key
        # followed by its label, e.g. `{reverse} ? {/reverse} Help`.
        private def format_entry(entry : Entry) : String
          tags = key_tags
          "#{tags[:open]} #{entry.key} #{tags[:close]} #{entry.label}"
        end

        # Translates `key_style` into open/close tags used around the key.
        private def key_tags
          if @key_style.reverse?
            {open: "{reverse}", close: "{/reverse}"}
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
