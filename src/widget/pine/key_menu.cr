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
        getter columns : Int32

        # Number of rows (Pine uses 2).
        getter rows : Int32

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
          # Tile the cells across the full content width with a real grid. The
          # naive per-column `100 // columns` percentage rounded each column
          # independently, so columns drifted apart (a stray cell of gap) and the
          # rightmost stopped short of the right edge whenever `columns` did not
          # divide the width evenly. `Layout::Grid` carves the interior by
          # *cumulative* integer fences (`col * inner // columns`) with `gap: 0`,
          # so columns abut exactly and the last reaches the edge for any
          # `columns`/width — the same split the old hand-rolled `#relayout` did,
          # now shared. Entries flow COLUMN-major (entry 0 top-left, entry 1
          # directly below, entry 2 top of the next column), which the row-major
          # auto-flow can't express, so `#build` gives every cell an explicit
          # `Grid::Hint` placing it at `{row: i % rows, col: i // rows}`.
          # Set the ivar directly (like `HeaderBar`) so no method runs before it.
          @layout = Crysterm::Layout::Grid.new(columns: @columns, rows: @rows, gap: 0)
          build
        end

        # Replaces all entries and rebuilds the display. Use this when switching
        # between Pine screens, each of which has its own command set.
        def set_entries(entries : Array(Entry))
          @entries = entries
          build
        end

        # Re-tile into a new column count: keep the grid layout in sync and rebuild
        # the cells (their per-cell `Grid::Hint` column index and the `col >= columns`
        # drop both depend on `columns`).
        def columns=(value : Int32) : Int32
          @columns = value
          if g = @layout.as?(Crysterm::Layout::Grid)
            g.columns = value
          end
          build
          value
        end

        # Change the row count: sync the grid and rebuild so each cell's row index
        # (`i % rows`) is reassigned. Does not resize the widget — its height was
        # set from `rows` at construction (pass `height:` to override).
        def rows=(value : Int32) : Int32
          @rows = value
          if g = @layout.as?(Crysterm::Layout::Grid)
            g.rows = value
          end
          build
          value
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

        # (Re)creates the child boxes for the current entries. Each cell carries a
        # `Grid::Hint` placing it at its column-major slot (`{row: i % rows,
        # col: i // rows}`); the `Layout::Grid` installed in `#initialize` then
        # tiles the columns gap-free across the full content width every frame.
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
              content: format_entry(entry),
              layout_hint: Crysterm::Layout::Grid::Hint.new(row: row, col: col),
            )

            # Clicking a hint acts like pressing its key: run the entry's callback
            # (the dispatch-table use) and emit `Event::Action` with the key so a
            # host can react (e.g. synthesize the keypress). `focus_on_click` is
            # off so clicking the bar doesn't steal focus from the active screen.
            box.focus_on_click = false
            box.on(::Crysterm::Event::Click) do
              entry.callback.try &.call
              emit ::Crysterm::Event::Action, entry.key
            end

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
