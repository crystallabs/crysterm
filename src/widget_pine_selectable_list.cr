require "./widget/list"

module Crysterm
  class Widget
    module Pine
      # Shared scaffolding for the Pine/Alpine selectable lists (`FolderList`,
      # `AddressBook`, `MessageIndex`, `MainMenu` and `Setup`).
      #
      # Each of those is a `Widget::List` that keeps a parallel array of *record*
      # objects (`T`) behind the visible text rows. The base provides what they
      # all share:
      #
      # * the selected row highlighted in reverse video,
      # * a backing `#records` array, replaced wholesale via `#set_records`
      #   (which rebuilds the rows through `#format_row`),
      # * `#selected_record`, the record under the cursor, and
      # * activation on `Event::ActionItem` (Enter / click), which by default
      #   runs the selected record's `callback`.
      #
      # A concrete subclass:
      #
      # * fixes the record type, e.g. `class FolderList < SelectableList(Folder)`
      #   (Crystal forbids naming a *nested* type in a class's own superclass
      #   clause, so each record class is declared at `Pine` scope and re-exposed
      #   under its historical nested name with an `alias`),
      # * implements `#format_row(item, index)` to render one record as a row,
      # * optionally overrides `#activate` (what Enter does), `#selected_index`
      #   (when visible rows don't map 1:1 to records) or `#rows` (to inject
      #   extra rows, e.g. spacers).
      abstract class SelectableList(T) < Widget::List
        # The records currently displayed, parallel to the visible rows.
        # (Named `records`, not `data`, to avoid colliding with `Widget#data`
        # — the unrelated `YAML::Any?` user-data slot from `Mixin::Data`.)
        getter records : Array(T)

        def initialize(data : Array(T) = [] of T, **list)
          # Assigned before `super` so the generic ivar is always initialized
          # (the compiler can't see the assignment through `#set_records`).
          @records = data

          super **list

          # Pine highlights the whole selected row in reverse video.
          styles.selected = Style.new reverse: true

          set_records data

          # Enter / click activates the current record.
          on ::Crysterm::Event::ActionItem do |_e|
            activate
          end
        end

        # Replaces the displayed records and rebuilds the visible rows.
        def set_records(data : Array(T))
          @records = data
          set_items rows(data)
        end

        # The record under the selection, if any.
        def selected_record : T?
          @records[selected_index]?
        end

        # Maps the selected *row* to the index of its record in `#records`. The
        # default is 1:1; override when rows and records don't line up (e.g.
        # `MainMenu`, which interleaves blank spacer rows).
        protected def selected_index : Int32
          selected
        end

        # Builds the visible row strings from *data*. The default renders one row
        # per record via `#format_row`; override to inject extra rows.
        protected def rows(data : Array(T)) : Array(String)
          data.map_with_index { |item, i| format_row item, i }
        end

        # Renders one record into its row string. *index* is the record's 0-based
        # position in `#records` (used e.g. for message numbering).
        abstract def format_row(item : T, index : Int32) : String

        # Invoked on `Event::ActionItem` (Enter / click). By default it runs the
        # selected record's `callback`; override for different behavior (e.g.
        # `Setup`, which toggles instead).
        def activate
          selected_record.try &.callback.try &.call
        end
      end
    end
  end
end
