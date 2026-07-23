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
      # Purely presentational: it binds no keys itself, so the `key` values here
      # must mirror the host's own key handler. `#trigger` lets the menu double
      # as a dispatch table.
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
          # At least one row: the cell math divides by `@rows`. `@columns` has
          # no division dependency, but `#build`'s `next if column >= @columns`
          # guard drops every entry when `@columns <= 0`, silently blanking
          # the menu — clamp both axes the same way.
          @rows = Math.max(1, @rows)
          @columns = Math.max(1, @columns)
          super **layout, width: w, height: (h || rows)
          # `spacing: 0` grid: columns abut on integer fences, so the last one reaches
          # the edge even when `columns` doesn't divide the width evenly. Entries
          # flow column-major, which auto-flow can't express, so every cell gets an
          # explicit `Grid::Hint`. Assigned to the ivar so no method runs before it.
          @layout = Crysterm::Layout::Grid.new(columns: @columns, rows: @rows, spacing: 0)
          build
        end

        # Replaces all entries and rebuilds the display. Use this when switching
        # between Pine screens, each of which has its own command set.
        def entries=(entries : Array(Entry))
          @entries = entries
          build
        end

        # Re-tiles into a new column count. Both the grid and the cells must be
        # rebuilt: each cell's `Grid::Hint` column depends on `columns`.
        def columns=(value : Int32) : Int32
          # `#build`'s `next if column >= @columns` guard drops every entry
          # when `@columns <= 0`, silently blanking the menu; at least one
          # column, mirroring `#rows=`.
          value = Math.max(1, value)
          @columns = value
          if g = @layout.as?(Crysterm::Layout::Grid)
            g.columns = value
          end
          build
          value
        end

        # Changes the row count and re-tiles. Does not resize the widget — its
        # height was set from `rows` at construction (pass `height:` to override).
        def rows=(value : Int32) : Int32
          # At least one row: the cell math divides by `@rows`.
          value = Math.max(1, value)
          @rows = value
          if g = @layout.as?(Crysterm::Layout::Grid)
            g.rows = value
          end
          build
          value
        end

        # Invokes the callback of the entry whose `key` matches *key* (if any),
        # returning `true` when something was triggered.
        def trigger(key : String) : Bool
          @entries.each do |e|
            if e.key == key
              e.callback.try &.call
              return true
            end
          end
          false
        end

        # (Re)creates the child boxes for the current entries, each carrying a
        # `Grid::Hint` for its column-major slot.
        private def build
          @cells.each &.remove_from_parent
          @cells.clear

          @entries.each_with_index do |entry, i|
            column = i // @rows
            row = i % @rows
            next if column >= @columns

            box = Widget::Box.new(
              window: window,
              parse_tags: true,
              content: format_entry(entry),
              layout_hint: Crysterm::Layout::Grid::Hint.new(row: row, column: column),
            )

            # Clicking a hint acts like pressing its key. `focus_on_click` is off
            # so the bar doesn't steal focus from the active screen.
            box.focus_on_click = false
            box.on(::Crysterm::Event::Click) do
              entry.callback.try &.call
              emit ::Crysterm::Event::Activated, entry.key
            end

            @cells << box
            append box
          end
        end
      end
    end
  end
end
