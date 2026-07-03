module Crysterm
  class Widget
    module Pine
      # The two-row command-key menu shown at the bottom of every Pine/Alpine
      # window.
      #
      # Each entry is a `key` (character the user presses) plus a short `label`.
      # Entries fill a grid of `columns` columns and (by default) two rows,
      # column-by-column like Pine: entry 0 top-left, entry 1 directly below,
      # entry 2 top of the next column, etc.
      #
      # Purely presentational — wire actual keys with a `Window`/`Widget`
      # `Event::KeyPress` handler (the `key` values here should mirror those
      # bindings). An entry's optional `callback` can be invoked via `#trigger`
      # to let the menu double as a dispatch table.
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
      # ![KeyMenu screenshot](../../../tests/widget/pine/key_menu/key_menu.5s.apng)
      # <!-- /widget-examples:capture -->
      class KeyMenu < Widget::Box
        include KeyBar

        # A single command hint in the menu.
        alias Entry = KeyBar::Item

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
          # `Layout::Grid` carves the interior by cumulative integer fences
          # (`col * inner // columns`) with `gap: 0`, so columns abut exactly and
          # the last reaches the edge even when `columns` doesn't divide the
          # width evenly (unlike a naive per-column `100 // columns` percentage).
          # Entries flow column-major, which row-major auto-flow can't express,
          # so `#build` gives each cell an explicit `Grid::Hint` at
          # `{row: i % rows, col: i // rows}`.
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

        # Re-tile into a new column count: sync the grid layout and rebuild the
        # cells (their `Grid::Hint` column index and the `col >= columns` drop
        # both depend on `columns`).
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
        # `Grid::Hint` at its column-major slot (`{row: i % rows, col: i // rows}`);
        # the `Layout::Grid` from `#initialize` tiles them gap-free every frame.
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
            # and emit `Event::Action` with the key so a host can react (e.g.
            # synthesize the keypress). `focus_on_click` off so the bar doesn't
            # steal focus from the active screen.
            box.focus_on_click = false
            box.on(::Crysterm::Event::Click) do
              entry.callback.try &.call
              emit ::Crysterm::Event::Action, entry.key
            end

            @cells << box
            append box
          end
        end
      end
    end
  end
end
